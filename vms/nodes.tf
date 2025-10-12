resource "libvirt_domain" "node_domain" {
  for_each   = { for node in local.all_nodes : node.name => node }
  name       = each.value.name
  memory     = each.value.memory_mib
  vcpu       = each.value.vcpus
  cloudinit  = each.value.role == "haproxy" ? libvirt_cloudinit_disk.haproxy_cloudinit_disk[each.key].id : null
  qemu_agent = true

  # Attach the main volume for all nodes
  dynamic "disk" {
    for_each = each.value.role != "haproxy" ? [1] : []
    content {
      volume_id = libvirt_volume.k8s_node_volume[each.key].id
    }
  }

  timeouts {
    create = "10m"
  }

  dynamic "disk" {
    for_each = each.value.role == "haproxy" ? [1] : []
    content {
      volume_id = libvirt_volume.haproxy_volume[each.key].id
    }
  }

  # Conditionally attach the Talos ISO for non-load-balancer nodes
  dynamic "disk" {
    for_each = each.value.role != "haproxy" && var.metaliso_absolute_path != null ? [1] : []

    content {
      file = var.metaliso_absolute_path
    }
  }

  network_interface {
    bridge = var.bridge_name
    mac    = "52:54:00:${substr(md5(each.key), 0, 2)}:${substr(md5(each.key), 2, 2)}:${substr(md5(each.key), 4, 2)}"
    # wait_for_lease = true
    addresses = [each.value.ip]
    hostname  = each.value.name
  }

  # Conditionally set boot order
  boot_device {
    dev = each.value.role == "haproxy" ? ["hd"] : ["cdrom", "hd"]
  }

  cpu {
    mode = "host-passthrough"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }

  xml {
    xslt = file("${path.module}/optimizations.xsl")
  }
  # lifecycle {
  #   prevent_destroy = var.prevent_destroy
  # }
}

