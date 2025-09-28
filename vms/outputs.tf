output "zone_id" {
  description = "The Cloudflare Zone ID"
  value       = data.cloudflare_zone.cloudflare_zone.zone_id
}

output "domain_name" {
  description = "The main domain name used for DNS records"
  value       = var.cloudflare_zone_name
}

output "dns_records" {
  description = "Map of created DNS records"
  value = {
    for name, record in cloudflare_dns_record.node_dns :
    record.name => {
      id      = record.id
      type    = record.type
      content = record.content
      ttl     = record.ttl
      proxied = record.proxied
    }
  }
}

