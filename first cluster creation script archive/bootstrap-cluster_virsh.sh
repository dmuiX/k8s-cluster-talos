#!/bin/bash

set -euo pipefail

# Enable debug mode if --debug flag is passed
if [[ "$1" == "--debug" ]]; then
  echo "--- DEBUG MODE ENABLED ---"
  set -x
  DEBUG=true
fi

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    echo "yq is not installed. I will install it."
    apt install -y yq
    # echo "Installation instructions: https://github.com/mikefarah/yq#install"
    exit 1
fi

# Get the current working directory
pwd=$(pwd)
echo "Current working directory: $pwd"

# Download the Talos metal ISO for AMD64 architecture
if [ -f "./metal-amd64.iso" ]; then
    echo "Talos metal ISO already exists. Skipping download."
else
    echo "Downloading Talos metal ISO..."
    while true; do
        if curl -L -o ./metal-amd64.iso https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso; then
            echo "Talos metal ISO downloaded successfully."
            break
        else
            echo "Failed to download the Talos metal ISO. Retrying in 5 seconds..."
            sleep 5
        fi
    done
fi

# Ensure the ISO file has the correct permissions
chmod 644 ./metal-amd64.iso
echo "Set permissions for Talos metal ISO to 644."

# Checksum the ISO file to ensure integrity
echo "Verifying Talos metal ISO integrity..."
sumfile=sha256sum.txt
curl -L -s -o ${sumfile} https://github.com/siderolabs/talos/releases/latest/download/${sumfile}
sha256sum -c --ignore-missing < ${sumfile}
echo "Talos metal ISO integrity verified."

# Find bridge interface
BRIDGE_NAME=$(ip -o link show type bridge | awk -F': ' '{print $2}' | head -n 1)
if [ -z "$BRIDGE_NAME" ]; then
    echo "No bridge interface found. Please create one and try again."
    exit 1
fi
echo "Found bridge interface: $BRIDGE_NAME"

# Create VMs from nodes.yaml
echo "Creating VMs..."
ISO_PATH=$(realpath ./metal-amd64.iso)
TEMPLATE_PATH=$(realpath ./domain-template.xml)

# Use process substitution for a more robust loop
while read -r name memory_mib vcpus; do
    echo "---"
    echo "Processing VM: $name"
    echo "Value for 'memory' (MiB): [${memory_mib}]"
    echo "Value for 'vcpus': [${vcpus}]"

    # Convert memory from MiB to KiB
    memory_kib=$((memory_mib * 1024))
    echo "Converted memory (KiB): [${memory_kib}]"
    echo "---"

    # Create a directory for the node's assets if it doesn't exist
    if [ ! -d "$name" ]; then
        mkdir -p "$name"
        echo "Created directory $name."
    fi

    VM_XML_PATH="./${name}/${name}.xml"
    DISK_PATH="/var/lib/libvirt/images/${name}.qcow2"
    SERIAL_LOG_PATH=$(realpath "./${name}/${name}-serial.log")
    CONSOLE_LOG_PATH=$(realpath "./${name}/${name}-console.log")

    if [ ${DEBUG} ]; then
        echo "---"
        echo "Removing existing disk image for $name..."
        echo "---"
        sudo rm -f "$DISK_PATH" # Remove any existing file to avoid conflicts DEBUGGING!
    fi
    # Create disk image if it doesn't exist
    if [ ! -f "$DISK_PATH" ]; then
        echo "Creating disk for $name..."
        sudo qemu-img create -f qcow2 "$DISK_PATH" 40G
        # Set correct permissions for libvirt to access the disk
        sudo chown libvirt-qemu:libvirt-qemu "$DISK_PATH"
        echo "Set ownership of $DISK_PATH"
    fi

    # Create VM XML from template
    sed -e "s|__VM_NAME__|${name}|g" \
        -e "s|__MEMORY_KiB__|${memory_kib}|g" \
        -e "s|__VCPUS__|${vcpus}|g" \
        -e "s|__DISK_PATH__|${DISK_PATH}|g" \
        -e "s|__ISO_PATH__|${ISO_PATH}|g" \
        -e "s|__SERIAL_LOG_PATH__|${SERIAL_LOG_PATH}|g" \
        -e "s|__CONSOLE_LOG_PATH__|${CONSOLE_LOG_PATH}|g" \
        -e "s|__BRIDGE_NAME__|${BRIDGE_NAME}|g" \
        "$TEMPLATE_PATH" > "$VM_XML_PATH"

    # Define and start the VM
    if ! sudo virsh dominfo "$name" &> /dev/null; then
        echo "Defining VM $name..."
        sudo virsh define "$VM_XML_PATH"
    fi

    if [ "$(sudo virsh domstate "$name")" != "running" ]; then
        echo "Starting VM $name..."
        sudo virsh start "$name"
    fi

    rm "$VM_XML_PATH"
done < <(yq -r '.nodes[] | .name + " " + .memory_mib + " " + .vcpus' nodes.yaml)

echo "VMs created successfully."

echo "Clean up metal iso..."
rm -f ./metal-amd64.iso
rm -f ./sha256sum.txt

# Initialize and apply Terraform cloudflare configuration
echo "Initializing and applying Terraform Cloudflare configuration."
cd $pwd/cloudflare
terraform init -input=false
terraform apply -auto-approve
echo "Terraform applied successfully."

if talosctl version &> /dev/null; then
    echo "talosctl is already installed."
else
    echo "Installing talosctl..."
    curl -sL https://talos.dev/install | sh
fi

# After the VMs are up, you can proceed with Talos configuration
# Make sure you have talosctl installed and accessible in your PATH
# Generate Talos configuration files for your cluster
# Pick an endpoint IP in the network but not used by any nodes, for example 192.168.121.100.
talosctl gen config my-cluster https://192.168.1.244:6443 --install-disk /dev/vda

#  < nodes.yaml

# #Edit controlplane.yaml to add the virtual IP you picked to a network interface under .machine.network.interfaces, for example:

#find out ip adresses of the vms
#set the ip adresses of the nodes.yaml in the machine section of controlplane.yaml and worker.yaml

# # Apply the configuration to the initial control plane node:
# talosctl -n 192.168.121.203 apply-config --insecure --file controlplane.yaml

# export TALOSCONFIG=$(realpath ./talosconfig)
# talosctl config endpoint 

# talosctl -n 192.168.121.203 bootstrap

# talosctl -n 192.168.121.119 apply-config --insecure --file controlplane.yaml
# talosctl -n 192.168.121.125 apply-config --insecure --file controlplane.yaml
# talosctl -n 192.168.121.69 apply-config --insecure --file worker.yaml

# talosctl -n 192.168.121.203 kubeconfig ./kubeconfig