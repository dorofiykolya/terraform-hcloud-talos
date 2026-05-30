resource "hcloud_placement_group" "control_plane" {
  name = "${local.cluster_prefix}control-plane"
  type = "spread"
  labels = {
    "cluster" = var.cluster_name
  }
}

resource "hcloud_placement_group" "worker" {
  name = "${local.cluster_prefix}worker"
  type = "spread"
  labels = {
    "cluster" = var.cluster_name
  }
}

locals {
  # Distinct, explicitly-named placement groups requested by worker nodes via
  # their optional `placement_group` field. Nodes without one fall back to the
  # shared `worker` group above (backward-compatible default).
  worker_custom_placement_groups = toset([
    for node in var.worker_nodes : node.placement_group
    if node.placement_group != null
  ])
}

resource "hcloud_placement_group" "worker_custom" {
  for_each = local.worker_custom_placement_groups
  name     = "${local.cluster_prefix}${each.value}"
  type     = "spread"
  labels = {
    "cluster" = var.cluster_name
  }
}
