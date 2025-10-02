# Create a cloud-init disk for the HAProxy node
resource "libvirt_cloudinit_disk" "haproxy_cloudinit" {
  name = "haproxy-cloudinit.iso"
  pool = "default"
  user_data = templatefile("${path.module}/haproxy_user_data.tpl", {
    control_nodes = [for node in local.k8s_nodes : node if node.role == "control-node"]
  })
  network_config = templatefile("${path.module}/haproxy_network_config.tpl", {
    ip_address  = var.ip
    gateway     = var.gateway
    bridge_name = var.bridge_name
  })
}

resource "libvirt_volume" "haproxy_ubuntu_basevolume" {
  name   = "${var.name}_ubuntu_basevolume.qcow2"
  pool   = "default"
  format = "qcow2"
  source = var.haproxy_base_volume_source
}

resource "libvirt_volume" "haproxy_volume" {
  name           = "${var.name}_volume.qcow2"
  pool           = "default"
  format         = "qcow2"
  size           = var.disk_size_gib * 1024 * 1024 * 1024
  base_volume_id = libvirt_volume.haproxy_ubuntu_basevolume.id

  lifecycle {
    prevent_destroy = true
  }
}

module "haproxy_node" {
  source = "../base_node" # Calls the generic base module

  # Pass through all the required variables
  name                   = var.name
  memory_mib             = var.memory_mib
  vcpus                  = var.vcpus
  ip                     = var.ip
  bridge_name            = var.bridge_name
  cloudinit_id           = libvirt_cloudinit_disk.haproxy_cloudinit.id
  volume_id              = libvirt_volume.haproxy_volume.id
  terraform_role         = var.terraform_role
  role                   = var.role
  disk_size_gib          = var.disk_size_gib
  metaliso_absolute_path = null
}
