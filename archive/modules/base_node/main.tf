resource "libvirt_domain" "node_domain" {
  name      = var.name
  memory    = var.memory_mib
  vcpu      = var.vcpus
  cloudinit = var.cloudinit_id

  disk {
    volume_id = var.volume_id
  }

  dynamic "disk" {
    for_each = var.role == "control-node" || var.role == "worker-node" ? [var.metaliso_absolute_path] : []
    content {
      file = disk.value
    }
  }

  network_interface {
    bridge    = var.bridge_name
    mac       = "52:54:00:${substr(md5(var.name), 0, 2)}:${substr(md5(var.name), 2, 2)}:${substr(md5(var.name), 4, 2)}"
    addresses = [var.ip]
    hostname  = var.name
  }

  boot_device {
    dev = var.role == "haproxy" ? ["hd"] : ["cdrom", "hd"]
  }

  cpu {
    mode = "host-passthrough"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      "network_interface",
      "disk",
    ]
  }
}
