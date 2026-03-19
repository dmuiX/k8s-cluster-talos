data "cloudflare_zone" "cloudflare_zone" {
  count = var.enable_cloudflare ? 1 : 0
  filter = {
    name = var.cloudflare_zone_name
  }
}

# Create Cloudflare DNS records dynamically for nodes
resource "cloudflare_dns_record" "node_dns" {
  for_each = var.enable_cloudflare ? { for node in local.all_nodes : node.name => node } : {}
  zone_id  = data.cloudflare_zone.cloudflare_zone[0].zone_id
  name     = "${each.value.name}.${var.cloudflare_zone_name}"
  type     = "A"
  content  = each.value.ip
  ttl      = 60
  proxied  = false # Set to true if you want Cloudflare to proxy traffic
}
