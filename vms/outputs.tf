output "zone_id" {
  description = "The Cloudflare Zone ID"
  value       = data.cloudflare_zone.cloudflare_zone.zone_id
}

output "domain_name" {
  description = "The main domain name used for DNS records"
  value       = var.cloudflare_zone_name
}

output "dns_records" {
  description = "A map of the created DNS records."
  value = {
    for name, content in cloudflare_dns_record.node_dns :
    name => content
  }
}

output "node_macs" {
  description = "Map of node names to their MAC addresses"
  value = {
    for name, domain in libvirt_domain.node_domain :
    name => domain.network_interface[0].mac
  }
}

#output "node_disks" {
#  description = "A map of all created nodes and their attached disks."
#
#  value = {
#    for node_key, node_resource in libvirt_domain.node_domain : node_key => {
#      # The 'disk' attribute is a list, so we can loop through it.
#      disks = [
#        for disk in node_resource.disk : {
#          # Depending on how you define your disks, one of these will be populated.
#          file      = disk.file
#          volume_id = disk.volume_id
#          url       = disk.url
#
#          # This is useful to see if it's a 'disk' or 'cdrom'.
#          # In your case, you'd see the 'cdrom' device disappear after you re-apply.
#          device = disk.device
#        }
#      ]
#    }
#  }
#}

#output "node_ips" {
#  description = "Map of node names to their IP addresses"
#  value = {
#    for name, domain in libvirt_domain.node_domain :
#    name => domain.network_interface[0].addresses[0]
#  }
#}
