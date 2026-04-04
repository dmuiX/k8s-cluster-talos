iso and base image
hmm unsure how i built them

have deleted them

yeah they are built by the script!

and still

╷
│ Error: error while retrieving remote ISO: error while downloading volume: error while downloading volume: Unable to open stream for '/var/lib/libvirt/images/haproxy-cloudinit.iso': No such file or directory
│
│   with libvirt_cloudinit_disk.haproxy_cloudinit_disk["haproxy"],
│   on haproxy.tf line 1, in resource "libvirt_cloudinit_disk" "haproxy_cloudinit_disk":
│    1: resource "libvirt_cloudinit_disk" "haproxy_cloudinit_disk" {
│
╵

yeah was the old terraform state

but good to know that the script is creating these files.!

cloud-init script works now with ubuntu 26.04! thats nice

# ubuntu image

UBUNTU_IMAGE_URL="<https://cloud-images.ubuntu.com/resolute/20260328/resolute-server-cloudimg-amd64.img>"
UBUNTU_CHECKSUM_URL="<https://cloud-images.ubuntu.com/resolute/20260328/SHA256SUMS>"
UBUNTU_IMAGE_PATH="/var/lib/libvirt/images/resolute-server-cloudimg-amd64.img"
