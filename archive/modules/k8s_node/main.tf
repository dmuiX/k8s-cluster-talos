resource "libvirt_volume" "k8s_volume" {
  name   = "${var.name}_volume.qcow2"
  pool   = "default"
  format = "qcow2"
  size   = var.disk_size_gib * 1024 * 1024 * 1024

  lifecycle {
    prevent_destroy = true
  }
}

module "k8s_node" {
  source = "../base_node" # Calls the generic base module

  # Pass through all the required variables
  name                   = var.name
  memory_mib             = var.memory_mib
  vcpus                  = var.vcpus
  ip                     = var.ip
  bridge_name            = var.bridge_name
  cloudinit_id           = null
  volume_id              = libvirt_volume.k8s_volume.id
  terraform_role         = var.terraform_role
  role                   = var.role
  disk_size_gib          = var.disk_size_gib
  metaliso_absolute_path = var.metaliso_absolute_path
}
