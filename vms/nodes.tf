resource "libvirt_volume" "node_volume" {
  for_each      = { for node in local.all_nodes : node.name => node }
  name          = "${each.value.name}.qcow2"
  pool          = "default"
  capacity      = each.value.disk_size_gib
  capacity_unit = "GiB"
  target = {
    format = {
      type = "qcow2"
    }
  }
}


resource "libvirt_domain" "node_domain" {

  for_each    = { for node in local.all_nodes : node.name => node }
  running     = true # das ding geht nich von alleine an :D lol 
  name        = each.value.name
  memory      = each.value.memory_mib
  memory_unit = "MiB"
  vcpu        = each.value.vcpus
  type        = "kvm"
  io_threads  = 2
  on_crash    = "restart"

  clock = {
    timer = [
      {
        name    = "hpet"
        present = "no"
      }
    ]
  }

  devices = {
    disks = [
      {
        driver = {
          type = "qcow2"
          io_threads = {
            io_thread = [
              { id = 1 }
            ]
          }
        }
        source = {
          volume = {
            pool   = "default"
            volume = libvirt_volume.node_volume[each.key].name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        source = {
          file = {
            file = var.metaliso_absolute_path
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      {
        link = {
          state = "up"
        }
        model = {
          type = "virtio"
        }
        source = {
          bridge = {
            bridge = var.bridge_name
          }
        }
        mac = {
          address = "52:54:00:${substr(md5(each.key), 0, 2)}:${substr(md5(each.key), 2, 2)}:${substr(md5(each.key), 4, 2)}"
        }
      }
    ]
    graphics = [
      {
        vnc = {
          listen   = "127.0.0.1"
          autoport = "yes"
        }
      }
    ]
    channels = [
      {
        source = {
          unix = {}
        }
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      }
    ]
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [
      { dev = "cdrom" },
      { dev = "hd" }
    ]
  }

  cpu = {
    mode  = "host-passthrough"
    check = "none"
    topology = {
      sockets = 1
      cores   = 2
      threads = 2
    }
    features = [
      {
        name   = "topoext"
        policy = "require"
      }
    ]
  }
}
