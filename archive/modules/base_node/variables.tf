variable "name" { type = string }
variable "memory_mib" { type = number }
variable "vcpus" { type = number }
variable "terraform_role" { type = string }
variable "role" { type = string }
variable "ip" { type = string }
variable "bridge_name" { type = string }
variable "disk_size_gib" { type = number }
variable "cloudinit_id" {
        type = string
        default = null
}
variable "volume_id" {
        type = string
        default = null
}
variable "metaliso_absolute_path" {
        type = string
        default = null
}
