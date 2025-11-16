# Talos Kubernetes Cluster

This repository contains the configuration for a Kubernetes cluster running on Talos.

## Overview

* **Virtualization:** KVM with terraform libvirt provider
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

does not work

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

## terraform prevent destroy works when remove the block from the tf files...
this is sooo weird
cannot set a variable but can remove the block and then apply....wtf.

## deployment on argocd

3. On argocd: 
    1. install k8s
    2. install cilium
    3. install external-dns
    4. install cert-manager
    5. install argocd
    6. install external-secrets
    7. install gateway-api
    8. install argocd-apps
   

## Upgrade or change to custom iso 

```bash
cd /home/nasadmin/k8s-cluster-talos && curl -sX POST "https://factory.talos.dev/schematics" -H "Content-Type: application/vnd.yaml" --data-binary @- <<'EOF' | jq -r '.id'
customization:
    systemExtensions:
        officialExtensions:
        - siderolabs/qemu-guest-agent
        - siderolabs/amd-ucode
        - siderolabs/util-linux-tools
        - siderolabs/iscsi-tools
EOF

export TALOSCONFIG=/home/nasadmin/k8s-cluster-talos/cluster/talosconfig && talosctl -n 192.168.1.21,192.168.1.22,192.168.1.23,192.168.1.31,192.168.1.32 upgrade --image factory.talos.dev/installer/99fb4dc739f1f7b255110f6f3c24ba98ea9903249de72570b22f0150be37650d:v1.11.2 --preserve --wait=false
```
