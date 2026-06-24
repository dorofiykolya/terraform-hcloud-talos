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
          # Floating IP configured as a STATIC /32 address on the public NIC
          # (busPath 0000:01:00.0 — Hetzner x86 predictable name; eth0 matches
          # nothing, see talos_patch_control_plane.tf). NOT the Talos `vip`: the
          # hcloud `vip` is driven by ETCD leader-election among CONTROL-PLANE
          # nodes (Talos's shared-IP feature) — a worker runs no etcd, so a `vip`
          # block there never elects and would silently never bind the IP. A
          # static address puts the Floating IP on the interface unconditionally
          # at boot; Hetzner routes the IP to this node via
          # hcloud_floating_ip_assignment.worker_egress (network.tf), so Cilium's
          # Egress Gateway can SNAT matched pod egress to it (set
          # egressGateway.egressIP to this IP). `dhcp = true` is kept so the
          # node still gets its primary public IP — the Floating IP is an
          # ADDITIONAL address. Recreation-stable: the IP value never changes, TF
          # re-binds the assignment, and the new node boots with the same static
          # address. It is NOT live auto-failover — the single egress worker is
          # the accepted SPOF of the dedicated-egress-anchor design. Non-egress
          # workers get NO interfaces block (default DHCP, byte-for-byte
          # unchanged → no machine-config churn).
          worker.egress_floating_ip ? {
            interfaces = [
              {
                deviceSelector = {
                  busPath = "0000:01:00.0"
                }
                dhcp = true
                addresses = [
                  "${hcloud_floating_ip.worker_egress_ipv4[worker.name].ip_address}/32"
                ]
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
