#!/bin/bash

# Exit if any command fails
set -e

# Make sure yq is installed (https://github.com/mikefarah/yq#install)
if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed. It is required to read nodes.yaml."
    sudo apt install yq -y
    exit 1
fi

# Read node names from the YAML file
NODE_NAMES=$(yq e '.nodes[].name' nodes.yaml)

# Loop through each node and remove it
for name in $NODE_NAMES; do
    echo "Removing node: $name"
    # Try to destroy the VM, ignore error if it's not running
    virsh destroy "$name" || true
    # Try to undefine the VM, ignore error if it's not defined
    virsh undefine "$name" --remove-all-storage || true
done

echo "Cleanup finished."