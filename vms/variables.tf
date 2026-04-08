variable "cloudflare_api_token" {
  description = "The Cloudflare API token."
  type        = string
  sensitive   = true
}

variable "libvirt_uri" {
  description = "The connection URI for the libvirt daemon. Defaults to 'qemu:///system' for local KVM."
  type        = string
}

variable "cloudflare_zone_name" {
  description = "The domain name to manage in Cloudflare."
  type        = string
}

variable "nodes_file_path" {
  description = "The path to the nodes.yaml file."
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

variable "github_owner" {
  description = "GitHub username or organization for repo URLs and SSH key import."
  type        = string
}

variable "enable_cloudflare" {
  description = "Enable Cloudflare DNS record creation. Set to false to skip."
  type        = bool
  default     = true
}
