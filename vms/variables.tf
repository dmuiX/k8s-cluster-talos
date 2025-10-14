variable "pihole_password" {
  description = "The password for the Pi-hole web interface."
  type        = string
  sensitive   = true
}

variable "pihole_server" {
  description = "The URL of the Pi-hole instance (e.g., http://pihole.local/admin)."
  type        = string
}

variable "domain_name" {
  description = "The domain name to manage in Pi-hole (e.g., example.local)."
  type        = string
}

variable "libvirt_uri" {
  description = "The connection URI for the libvirt daemon. Defaults to 'qemu:///system' for local KVM."
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

variable "cloudinit_basevolume_url" {
  description = "URL or path to the source image for haproxy (e.g., a cloud image)."
  type        = string
}
