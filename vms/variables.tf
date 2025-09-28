variable "cloudflare_api_token" {
  description = "The Cloudflare API token."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_name" {
  description = "The domain name to manage in Cloudflare."
  type        = string
}

variable "nodes_yaml_content" {
  description = "The content of the nodes.yaml file."
  type        = string
}

variable "metaliso_absolute_path" {
  description = "The absolute path to the Talos metal ISO."
  type        = string
}

variable "bridge_name" {
  description = "The name of the libvirt bridge to attach VMs to."
  type        = string
}