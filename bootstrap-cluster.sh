#!/bin/bash

set -euo pipefail

# Get the current working directory
pwd=$(pwd)
echo "Current working directory: $pwd"

# Function to clean up VMs on failure
cleanup_vms() {
    echo "--- Cleaning up VMs ---"
    if ! command -v yq &> /dev/null; then
        echo "Error: yq is not installed. Cannot perform cleanup."
        # We don't exit here, just warn, as the main script will exit anyway.
        return 1
    fi

    # Ensure NODES_FILE is available, falling back to a default
    local nodes_file="${pwd}/${NODES_FILE:-nodes.yaml}"
    if [ ! -f "$nodes_file" ]; then
        echo "Warning: Nodes file not found at $nodes_file. Cannot perform cleanup."
        return 1
    fi

    local node_names
    node_names=$(yq e '.nodes[].name' "$nodes_file")

    for name in $node_names; do
        echo "Removing node: $name"
        virsh destroy "$name" >/dev/null 2>&1 || true
        virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 || true
    done
    echo "--- Cleanup finished ---"
}

# Load environment variables from .env file
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

# Parse command-line arguments
SKIP_VAGRANT=false
SKIP_TERRAFORM=false
SKIP_ISO_DOWNLOAD=false
DEBUG=false
for arg in "$@"
do
    case $arg in
        --skip-iso-download)
        SKIP_ISO_DOWNLOAD=true
        shift # Remove --skip-iso-download from processing
        ;;
        --skip-terraform)
        SKIP_TERRAFORM=true
        shift # Remove --skip-terraform from processing
        ;;
        --debug)
        DEBUG=true
        shift # Remove --debug from processing
        ;;
        --cleanup-vms)
        cleanup_vms
        exit 0
        shift # Remove --cleanup-vms from processing
        ;;
    esac
done

# Enable debug mode if debug flag is passed
if [[ "$DEBUG" == "true" ]]; then
  echo "--- DEBUG MODE ENABLED ---"
  set -x
fi

# initialize and start vagrant vms

if [ "$SKIP_ISO_DOWNLOAD" = false ]; then
    cd "${VMS_DIR}"
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
    sudo chmod 644 ./metal-amd64.iso
    echo "Set permissions for Talos metal ISO to 644."

    # Checksum the ISO file to ensure integrity
    echo "Verifying Talos metal ISO integrity..."
    sumfile=sha256sum.txt
    curl -L -s -o ${sumfile} https://github.com/siderolabs/talos/releases/latest/download/${sumfile}
    sha256sum -c --ignore-missing < ${sumfile}
    echo "Talos metal ISO integrity verified."

    # echo "VMs created successfully."

else
    echo "Skipping iso-download as requested."
fi

# terraform cloudflare
if [ "$SKIP_TERRAFORM" = false ]; then
    # cloudflare + libvirt vms terraform
    # Find bridge interface
    BRIDGE_NAME=$(ip -o link show type bridge | awk -F': ' '{print $2}' | head -n 1)
    if [ -z "$BRIDGE_NAME" ]; then
        echo "No bridge interface found. Please create one and try again."
        exit 1
    fi

    cd $pwd/"${VMS_DIR}"
    
    echo "Found bridge interface: $BRIDGE_NAME"
    export TF_VAR_bridge_name=$BRIDGE_NAME

    # Initialize and apply Terraform cloudflare configuration
    echo "Initializing and applying Terraform Cloudflare configuration."
    
    terraform init -input=false
    if ! terraform apply -auto-approve; then
        echo "Terraform apply failed."
        echo "cleaning up created VMs..."
        cleanup_vms
        exit 1
    fi
    echo "Terraform applied successfully."
fi

# bootstrap talos cluster

# talosctl configuration
cd $pwd/"${CLUSTER_DIR}"

# Check if talosctl is installed, if not, install it
if ! command -v talosctl &> /dev/null; then
    echo "Installing talosctl..."
    curl -sL https://talos.dev/install | sh
fi

# After the VMs are up, you can proceed with Talos configuration
# Make sure you have talosctl installed and accessible in your PATH
# Generate Talos configuration files for your cluster
# Pick an endpoint IP in the network but not used by any nodes, for example 192.168.121.100.

if [ -f "controlplane.yaml" ]; then
    echo "Generating Talos configuration files..."
    talosctl gen config my-cluster https://192.168.1.244:6443 --install-disk /dev/vda
fi

#  < nodes.yaml

# #Edit controlplane.yaml to add the virtual IP you picked to a network interface under .machine.network.interfaces, for example:

#find out ip adresses of the vms
VM_IPS=$(virsh net-dhcp-leases --network vagrant-libvirt | awk '{print $5}')
echo "VM IPs: $VM_IPS"

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

if [ "${DEBUG-}" != true ]; then
    echo "Clean up metal iso..."
    rm -f $pwd/vagrant/metal-amd64.iso
    rm -f $pwd/vagrant/sha256sum.txt
fi