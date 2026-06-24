locals {
  # Generate YAML for all workers
  worker_yaml = {
    for worker in local.workers : worker.name => {
      machine = {
        install = {
          image = "ghcr.io/siderolabs/installer:${var.talos_version}"
        }
        certSANs = local.cert_SANs
        kubelet = merge(
          {
            extraArgs = merge(
              {
                "cloud-provider"             = "external"
                "rotate-server-certificates" = true
              },
              var.kubelet_extra_args
            )
            nodeIP = {
              validSubnets = [
                local.node_ipv4_cidr
              ]
            }
          },
          # Add registerWithTaints if taints are defined
          length(worker.taints) > 0 ? {
            extraConfig = {
              registerWithTaints = [
                for taint in worker.taints : {
                  key    = taint.key
                  value  = taint.value
                  effect = taint.effect
                }
              ]
            }
          } : {}
        )
        network = merge(
          {
            extraHostEntries = local.extra_host_entries
            kubespan = {
              enabled = var.enable_kube_span
              advertiseKubernetesNetworks : false # Disabled because of cilium
              mtu : 1370                          # Hcloud has a MTU of 1450 (KubeSpanMTU = UnderlyingMTU - 80)
            }
          },
          # Egress workers (egress_floating_ip = true) get their dedicated
          # Floating IP configured as an hcloud-managed VIP on the public NIC.
          # Same busPath selector as the control-plane VIP (0000:01:00.0 — Talos
          # 1.12+ predictable names; eth0 matches nothing, see
          # talos_patch_control_plane.tf). This puts the Floating IP onto the
          # node's interface so Cilium's Egress Gateway can SNAT matched pod
          # egress to it, and Talos keeps the IP assigned to this node via the
          # hcloud API. Non-egress workers get NO interfaces block at all — both
          # NICs keep their default DHCP config (byte-for-byte unchanged → no
          # machine-config churn on existing workers).
          worker.egress_floating_ip ? {
            interfaces = [
              {
                deviceSelector = {
                  busPath = "0000:01:00.0"
                }
                dhcp = true
                vip = {
                  ip = hcloud_floating_ip.worker_egress_ipv4[worker.name].ip_address
                  hcloud = {
                    apiToken = var.hcloud_token
                  }
                }
              }
            ]
          } : {}
        )
        kernel = {
          modules = var.kernel_modules_to_load
        }
        sysctls = merge(
          {
            "net.core.somaxconn"          = "65535"
            "net.core.netdev_max_backlog" = "4096"
          },
          var.sysctls_extra_args
        )
        features = {
          hostDNS = {
            enabled              = true
            forwardKubeDNSToHost = true
            resolveMemberNames   = true
          }
        }
        time = {
          servers = [
            "ntp1.hetzner.de",
            "ntp2.hetzner.com",
            "ntp3.hetzner.net",
            "time.cloudflare.com"
          ]
        }
        nodeLabels = worker.labels
        registries = var.registries
      }
      cluster = {
        network = {
          dnsDomain = var.cluster_domain
          podSubnets = [
            local.pod_ipv4_cidr
          ]
          serviceSubnets = [
            local.service_ipv4_cidr
          ]
          cni = {
            name = "none"
          }
        }
      }
    }
  }
}
