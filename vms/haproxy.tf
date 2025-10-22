resource "libvirt_cloudinit_disk" "haproxy_cloudinit_disk" {
  for_each = { for node in local.all_nodes : node.name => node if node.role == "haproxy" }
  name     = "${each.value.name}-cloudinit.iso"
  pool     = "default"
  user_data = templatefile("${path.module}/haproxy_user_data.tpl", {
    control_nodes = [for node in local.all_nodes : node if node.role == "control-node"],
    username      = var.haproxy_username,
    user_password = var.haproxy_password
  })
  network_config = templatefile("${path.module}/haproxy_network_config.tpl", {
    ip_address  = each.value.ip
    gateway     = each.value.gateway
    nameservers = each.value.nameservers
  })
}

resource "libvirt_volume" "cloudinit_basevolume" {
  for_each = { for node in local.all_nodes : node.name => node if node.role == "haproxy" }
  name     = "${each.value.name}_cloudinit_basevolume.qcow2"
  pool     = "default"
  format   = "qcow2"
  source   = var.cloudinit_basevolume_url
}

resource "libvirt_volume" "haproxy_volume" {
  for_each       = { for node in local.all_nodes : node.name => node if node.role == "haproxy" }
  name           = "${each.value.name}_volume.qcow2"
  pool           = "default"
  format         = "qcow2"
  size           = each.value.disk_size_gib * 1024 * 1024 * 1024
  base_volume_id = libvirt_volume.cloudinit_basevolume[each.key].id

  # lifecycle {
  #   prevent_destroy = var.prevent_destroy
  # }
}
