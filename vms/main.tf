terraform {
  required_version = ">= 0.13"
  cloud {
    organization = "dmuiX"
    workspaces {
      name = "k8s-cluster-talos"
    }
  }
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~>0.8.3"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "cloudflare_zone" "cloudflare_zone" {
  filter = {
    name = var.cloudflare_zone_name
  }
}

locals {
  nodes               = yamldecode(var.nodes_yaml_content)["nodes"]
  control_nodes = [for node in local.nodes : node if node.role == "control-node"]
  load_balancer_node  = one([for node in local.nodes : node if node.role == "load-balancer"])
}

# Create Cloudflare DNS records dynamically for nodes
resource "cloudflare_dns_record" "node_dns" {
  for_each = { for node in local.nodes : node.name => node }
  zone_id  = data.cloudflare_zone.cloudflare_zone.zone_id
  name     = "${each.value.name}.${var.cloudflare_zone_name}"
  type     = "A"
  content  = each.value.ip
  ttl      = 60
  proxied  = false # Set to true if you want Cloudflare to proxy traffic
}

provider "libvirt" {
  uri = "qemu:///system"
}

# Create a cloud-init disk for the HAProxy node
resource "libvirt_cloudinit_disk" "haproxy_cloudinit" {
  name = "haproxy-cloudinit.iso"
  pool = "default"
  user_data = templatefile("${path.module}/haproxy_user_data.tpl", {
    control_nodes = local.control_nodes
    ip_address  = local.load_balancer_node.ip
    gateway     = local.load_balancer_node.gateway
    nameservers = local.load_balancer_node.nameservers
  })
}

resource "libvirt_volume" "node_volume" {
  for_each = { for node in local.nodes : node.name => node }
  name     = each.value.name
  pool     = "default"
  format   = "qcow2"
  size     = 10 * 1024 * 1024 * 1024 # 10 GiB
}

resource "libvirt_domain" "node_domain" {
  for_each = { for node in local.nodes : node.name => node }
  name     = each.value.name
  memory   = each.value.memory_mib
  vcpu     = each.value.vcpus
  cloudinit = each.value.role == "load-balancer" ? libvirt_cloudinit_disk.haproxy_cloudinit.id : null

  # Conditionally attach the Talos ISO for non-load-balancer nodes
  dynamic "disk" {
    for_each = each.value.role == "control-node" ? [1] : []
    content {
      file = var.metaliso_absolute_path
    }
  }

  network_interface {
    bridge    = var.bridge_name
    mac       = "52:54:00:${substr(md5(each.key), 0, 2)}:${substr(md5(each.key), 2, 2)}:${substr(md5(each.key), 4, 2)}"
    addresses = [each.value.ip]
    hostname  = each.value.name
  }

  # Conditionally set boot order
  boot_device {
    dev = each.value.role == "load-balancer" ? ["hd"] : ["cdrom", "hd"]
  }

  cpu {
    mode = "host-passthrough"
  }

  # Attach the main volume for all nodes
  disk {
    volume_id = libvirt_volume.node_volume[each.key].id
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }
}
