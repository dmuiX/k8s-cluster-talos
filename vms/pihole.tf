resource "pihole_dns_record" "record" {
  for_each = { for node in local.all_nodes : node.name => node }
  domain   = "${each.value.name}.${var.domain_name}"
  ip       = each.value.ip
}
