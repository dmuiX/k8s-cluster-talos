resource "libvirt_volume" "k8s_node_volume" {
  for_each = { for node in local.all_nodes : node.name => node if node.role != "haproxy" }
  name     = each.value.name
  pool     = "default"
  format   = "qcow2"
  size     = each.value.disk_size_gib * 1024 * 1024 * 1024

  # lifecycle {
  #   prevent_destroy = var.prevent_destroy
  # }
}
