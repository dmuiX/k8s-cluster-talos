# Talos Kubernetes Cluster

This repository contains the configuration for a Kubernetes cluster running on Talos.

## Overview

* **Virtualization:** KVM with Vagrant
* **Operating System:** Talos
* **DNS:** Cloudflare (managed with Terraform)
* **Automation:** Automated node deployment for control plane and worker nodes.

## Directory Structure

* `cluster/`: Kubernetes manifests and Talos configuration files.
* `docs/`: Project documentation.
* `scripts/`: Helper scripts for cluster management.
* `terraform/`: Terraform configurations for Cloudflare DNS.
* `vagrant/`: Vagrantfile and related scripts for VM provisioning.

## Vagrant libvirt-provider

very old version 2 years old!

always getting: Call to virConnectListAllInterfaces failed: this function is not supported by the connection driver: virConnectListAllInterfaces (Libvirt::RetrieveError)

and defining a boot order is also not working very well

        domain.boot 'hd'
        domain.boot 'cdrom'
        # domain.boot_order = ['cdrom', 'hd']

## terraform libvirt provider

seems like for any reason this is not working for any reason:

  disk = [
    {
      volume_id = libvirt_volume.volume1.id
    },
    {
      volume_id = libvirt_volume.volume2.id
    }
  ]

## Error: failed to connect: dial unix /var/run/libvirt/libvirt-sock: connect: no such file or directory

I need to set the terraform cloud to Local Execution!

Default is Remote!

## Shell script attempt

Was trying to use a shell script but thought this will be very demanding to create I want to use sth that is working and can spin up and destroy stuff easy!

## cloudinit works but must be in one line!

## kernel parameter seem to end in kernel panic I will not use it then
  kernel = each.value.role == "control-node" ? "${path.module}/vmlinuz" : null
  cmdline = each.value.role == "control-node" ? [{key = "ip", value = "${each.value.ip}::${each.value.gateway}:255.255.255.0::eth0.100:::::"}] : null

## 