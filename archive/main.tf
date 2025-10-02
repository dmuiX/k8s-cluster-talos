locals {
  all_nodes = yamldecode(file("${path.module}/nodes.yaml"))["nodes"]
  
  # This split is the key to isolating changes!
  haproxy_nodes = { for node in local.all_nodes : node.name => node if node.role == "load-balancer" }
  control_nodes = { for node in local.all_nodes : node.name => node if node.role == "control-node" }
  worker_nodes  = { for node in local.all_nodes : node.name => node if node.role == "worker-node" }
}

# --- HAProxy Nodes ---
module "haproxy" {
  for_each = local.haproxy_nodes

  source = "./modules/haproxy_node"

  # Pass values directly
  name         = each.value.name
  memory_mib   = each.value.memory_mib
  vcpus        = each.value.vcpus
  ip           = each.value.ip
  role         = each.value.role
  bridge_name = var.bridge_name
  disk_size_gib = each.value.disk_size_gib 

  metaliso_absolute_path = null
  cloudinit_id = libvirt_cloudinit_disk.haproxy_cloudinit.id # Specific to this group
  base_volume_id = libvirt_volume.haproxy_basevolume.id
  prevent_destruction = false
}

# --- Control Plane Nodes ---
module "control_nodes" {
  for_each = local.control_nodes

  source = "./modules/node"
  
  # Pass values directly
  name        = each.value.name
  memory_mib      = each.value.memory_mib
  vcpus        = each.value.vcpus
  ip          = each.value.ip
  role        = each.value.role
  bridge_name = var.bridge_name
  disk_size_gib = each.value.disk_size_gib

  metaliso_absolute_path = var.metaliso_absolute_path
  prevent_destruction = true
  cloudinit_id = null
  base_volume_id = null
}

# --- Worker Nodes ---
module "worker_nodes" {
  for_each = local.worker_nodes

  source = "./modules/node"
  
  # Pass values directly
  name        = each.value.name
  memory_mib  = each.value.memory_mib
  vcpus       = each.value.vcpus
  ip          = each.value.ip
  role        = each.value.role
  bridge_name = var.bridge_name
  disk_size_gib = each.value.disk_size_gib

  metaliso_absolute_path = var.metaliso_absolute_path
  prevent_destruction = true
  cloudinit_id = null
  base_volume_id = null
}