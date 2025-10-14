#!/bin/bash

# ==============================================================================
# Talos Kubernetes Cluster Bootstrap Script
# ==============================================================================
# This script automates the complete setup of a Talos Linux Kubernetes cluster
# on KVM/libvirt with HAProxy load balancer and Cloudflare DNS.
#
# Prerequisites:
#   - KVM/libvirt installed and running
#   - Bridge network configured (e.g., br0)
#   - Cloudflare account with API token
#   - terraform cloud account with API Token or some other way to store the state file
#   - .env file with required variables (see .env.example)
#   - .envrc file for direnv and manual terraform deployment (optional)
#   - nodes.yaml file with node definitions
#     Example: 
#     - name: Unique node name (e.g., cqontrol-node-1)
#     - role: "control-node", "worker-node", or "haproxy"
#     - ip: Static IP address for the node
#     - mac: MAC address for the node (optional, auto-generated if missing)
#     - vcpus: Number of vCPUs for the node (optional, default: 2)
#     - memory_mib: RAM in MiB for the node (optional, default: 2048)
#     - disk_size_gib: Disk size in GiB for the node (optional, default: 20)
#   - Talos ISO and Ubuntu image download URLs in .env
#   - yq, jq, arp-scan installed
#
# Usage:
#   ./bootstrap-cluster.sh [options]
#
# OPTIONS:
#     -h, --help              Show this help message and exit
#     --skip-iso-download     Skip downloading Talos ISO and Ubuntu image
#     --skip-terraform        Skip VM creation (use existing VMs)
#     --skip-config-creation  Skip generating Talos configs (use existing configs)
#     --skip-bootstrap        Skip cluster bootstrap (use existing cluster)
#     --skip-cilium-installation  Skip Cilium CNI installation
#     --skip-argocd-installation  Skip ArgoCD installation
#     --skip-fluxcd-installation  Skip FluxCD installation
#     --debug                 Enable verbose bash debug mode (set -x)
#     --no-cleanup            Disable automatic terraform destroy on error
#     --cleanup-vms           Destroy only VMs (keeps Cloudflare DNS records)
#     --cleanup-all           Complete cleanup: VMs + DNS (terraform destroy)
#
# ==============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# ==============================================================================
# Help Function
# ==============================================================================
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Talos Kubernetes Cluster Bootstrap Script
Automates the complete setup of a Talos Linux Kubernetes cluster on KVM/libvirt.

OPTIONS:
    -h, --help              Show this help message and exit
    --skip-iso-download     Skip downloading Talos ISO and Ubuntu image
    --skip-terraform        Skip VM creation (use existing VMs)
    --skip-config-creation  Skip generating Talos configs (use existing configs)
    --skip-bootstrap        Skip cluster bootstrap (use existing cluster)
    --skip-cilium-installation  Skip Cilium CNI installation
    --skip-argocd-installation  Skip ArgoCD installation
    --skip-fluxcd-installation  Skip FluxCD installation
    --debug                 Enable verbose bash debug mode (set -x)
    --no-cleanup            Disable automatic terraform destroy on error
    --cleanup-vms           Destroy only VMs (keeps Cloudflare DNS records)
    --cleanup-all           Complete cleanup: VMs + DNS (terraform destroy)

EXAMPLES:
    # Full cluster setup (first time)
    ./bootstrap-cluster.sh

    # Skip downloads if already downloaded
    ./bootstrap-cluster.sh --skip-iso-download

    # Debug mode
    ./bootstrap-cluster.sh --debug

    # Quick cleanup (VMs only)
    ./bootstrap-cluster.sh --cleanup-vms

    # Complete cleanup (VMs + DNS)
    ./bootstrap-cluster.sh --cleanup-all

PREREQUISITES:
    - KVM/libvirt installed and running
    - Bridge network configured (e.g., br0)
    - Cloudflare account with API token
    - .env file with required variables
    - nodes.yaml file with node definitions

EOF
    exit 0
}

# ==============================================================================
# Error Handling and Cleanup
# ==============================================================================
# This function runs when the script exits with an error
# It performs terraform destroy to clean up partially created infrastructure
# ==============================================================================

CLEANUP_ON_ERROR=true  # Can be set to false with --no-cleanup flag

cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ "$CLEANUP_ON_ERROR" = true ]; then
        echo ""
        echo "========================================"
        echo "ERROR: Script failed with exit code $exit_code"
        echo "========================================"
        echo -e "\n⚠ The script encountered an error."
        echo -e "\nDo you want to clean up the infrastructure? (VMs will be destroyed)"
        read -p "Type 'yes' to destroy VMs and cleanup, or 'no' to keep them: " -r
        echo
        
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "Skipping cleanup. VMs and configs are preserved."
            echo "To manually cleanup later, run: ./bootstrap-cluster.sh --cleanup-all"
            return
        fi
        
        echo -e "==> Cleaning up infrastructure..."
        
        # Navigate to vms directory and run terraform destroy
        if [ -n "${VMS_DIR:-}" ] && [ -d "$VMS_DIR" ]; then
            echo "Running terraform destroy to clean up VMs..."
            cd "$VMS_DIR"
            terraform destroy -auto-approve
            echo "✓ VMs destroyed"
        else
            echo "Warning: Could not locate VMS_DIR for cleanup."
        fi
        
        # Clean up cluster directory (remove all generated configs)
        if [ -n "${CLUSTER_DIR:-}" ] && [ -d "$CLUSTER_DIR" ]; then
            echo "Cleaning up cluster configuration files..."
            cd "$CLUSTER_DIR"
            rm -rf ./node-configs 2>/dev/null
            rm -f ./*-patched.yaml ./talosconfig 2>/dev/null
            echo "✓ Cluster configs removed (kept: secrets.yaml)"
        fi
        
        echo "Cleanup complete. You can re-run the script to try again."
    fi
}

# Set trap to run cleanup on script exit (only if error occurs)
trap cleanup_on_error EXIT

# ==============================================================================
# Initial Setup and Configuration
# ==============================================================================

# Store current working directory (project root)
pwd=$(pwd)
echo "Current working directory: $pwd"

# Determine if we need sudo for privileged operations
# SUDO variable is used throughout the script for commands requiring root
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

# ==============================================================================
# Cleanup Functions
# ==============================================================================

# ------------------------------------------------------------------------------
# cleanup_vms_only: Remove only VMs (keeps Cloudflare DNS records)
# Used for: Quick VM cleanup without touching DNS
# ------------------------------------------------------------------------------
cleanup_vms_only() {
    echo -e "\n==> Cleaning up VMs (keeping DNS records)..."
    
    # Check if yq is available for parsing YAML
    if ! command -v yq &> /dev/null; then
        echo "Error: yq is not installed. Cannot perform cleanup."
        return 1
    fi

    # Locate nodes file (use env var or default)
    local nodes_file_path="${NODES_FILE_PATH:-../nodes.yaml}"
    if [ ! -f "$nodes_file_path" ]; then
        echo "Warning: Nodes file not found at $nodes_file_path. Cannot perform cleanup."
        return 1
    fi

    # Extract all node names from nodes.yaml
    local node_names
    node_names=$(yq e '.nodes[].name' "$nodes_file_path")

    # Destroy and undefine each VM
    for name in $node_names; do
        echo "Removing node: $name"
        virsh destroy "$name" >/dev/null 2>&1 || true  # Force stop VM
        virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 || true  # Delete VM and disks
    done
    echo "--- Cleanup finished ---"
}

# ==============================================================================
# Load Environment Variables
# ==============================================================================
# Load configuration from .env file if it exists
# Expected variables:
#   - CLUSTER_NAME: Name of the Kubernetes cluster
#   - VMS_DIR: Directory containing Terraform configs
#   - CLUSTER_DIR: Directory for Talos configs
#   - NODES_FILE_PATH: Path to nodes.yaml
#   - TALOS_ISO_URL, UBUNTU_IMAGE_URL: Download URLs
#   - TF_VAR_*: Terraform variables (Cloudflare, libvirt, etc.)
# ==============================================================================

if [ -f .env ]; then
    set -a  # Automatically export all variables
    source .env
    set +a  # Disable auto-export
fi

# ==============================================================================
# Parse Command-Line Arguments
# ==============================================================================

SKIP_TERRAFORM=false
SKIP_ISO_DOWNLOAD=false
SKIP_CONFIG_CREATION=false
SKIP_BOOTSTRAP=false
SKIP_CILIUM_INSTALLATION=false
SKIP_ARGOCD_INSTALLATION=true
SKIP_FLUXCD_INSTALLATION=false
DEBUG=false

for arg in "$@"; do
    case $arg in
        -h|--help)
            show_help
            ;;
        --skip-iso-download)
            SKIP_ISO_DOWNLOAD=true
            shift
            ;;
        --skip-terraform)
            SKIP_TERRAFORM=true
            shift
            ;;
        --skip-config-creation)
            SKIP_CONFIG_CREATION=true
            shift
            ;;
        --skip-bootstrap)
            SKIP_BOOTSTRAP=true
            shift
            ;;
        --skip-cilium-installation)
            SKIP_CILIUM_INSTALLATION=true
            shift
            ;;
        --skip-argocd-installation)
            SKIP_ARGOCD_INSTALLATION=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --no-cleanup)
            CLEANUP_ON_ERROR=false
            echo "Automatic cleanup on error is disabled."
            shift
            ;;
        --cleanup-vms)
            cleanup_vms_only
            exit 0
            ;;
        --cleanup-all)
            echo -e "\n==> Complete cleanup (VMs + DNS)..."
            if [ -n "${VMS_DIR:-}" ] && [ -d "$VMS_DIR" ]; then
                cd "$VMS_DIR"
                terraform destroy
            else
                echo "Error: VMS_DIR not found"
                exit 1
            fi
            # Clean up ALL cluster configs including secrets
            if [ -n "${CLUSTER_DIR:-}" ] && [ -d "$CLUSTER_DIR" ]; then
                cd "$CLUSTER_DIR"
                rm -rf ./node-configs 2>/dev/null
                rm -f ./controlplane.yaml ./worker.yaml ./*-patched.yaml ./talosconfig ./secrets.yaml 2>/dev/null
                echo "✓ All cluster configs removed"
            fi
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use -h or --help to see available options."
            exit 1
            ;;
    esac
done

if [[ "$DEBUG" == "true" ]]; then
    echo "--- DEBUG MODE ENABLED ---"
    set -x
fi

# ==============================================================================
# Helper Function: Ensure Custom Talos ISO
# ==============================================================================
# Creates a custom Talos ISO with system extensions:
#   - qemu-guest-agent: Better VM integration
#   - amd-ucode: AMD microcode updates
#   - util-linux-tools: Additional utilities
#
# Uses Talos Image Factory API to generate custom ISO with schematic ID
# ==============================================================================

# ==============================================================================
# Generic download function with retry and checksum verification
# ==============================================================================

download_and_verify() {
    local name="$1"
    local url="$2"
    local dest="$3"
    local checksum_url="$4"
    local pattern="$5"
    local use_sudo="${6:-false}"
    local fatal="${7:-true}"

    echo "==> Checking ${name}..."
    
    if [ -f "$dest" ]; then
        echo "${name} already exists."
        return 0
    fi

    local cmd_prefix=""
    if [ "$use_sudo" = "true" ]; then
        cmd_prefix="$SUDO"
    fi
    
    echo "==> Checking ${name}..."
    
    if $cmd_prefix test -f "$dest"; then
        echo "${name} already exists."
        return 0
    fi
    
    # Download with 3 retries
    echo "Downloading ${name}..."
    for i in {1..3}; do
        if $cmd_prefix curl -L --progress-bar -o "$dest" "$url"; then
            echo "✓ Downloaded successfully."
            $cmd_prefix chmod 644 "$dest"
            break
        fi
        
        if [ $i -lt 3 ]; then
            echo "Retry $i/3..."
            $cmd_prefix rm -f "$dest"
            sleep 5
        else
            echo "✗ Download failed after 3 attempts"
            if [ "$fatal" = "true" ]; then
                exit 1
            else
                return 1
            fi
        fi
    done
    
    # Verify checksum if provided
    if [ -z "$checksum_url" ]; then
        return 0
    fi
    
    echo "Verifying integrity..."
    local tmp="/tmp/checksum-$$.txt"
    
    if ! curl -sL "$checksum_url" > "$tmp"; then
        echo "WARNING: Checksum download failed."
        return 0
    fi
    
    if [ -n "$pattern" ]; then
        # Extract checksum for specific file pattern
        local expected=$(grep "$pattern" "$tmp" | awk '{print $1}')
        local actual=$($cmd_prefix sha256sum "$dest" | awk '{print $1}')
        
        if [ "$expected" = "$actual" ]; then
            echo "✓ Verified."
        else
            echo "✗ Checksum mismatch!"
            $cmd_prefix rm -f "$dest"
            rm -f "$tmp"
            if [ "$fatal" = "true" ]; then
                exit 1
            else
                return 1
            fi
        fi
    else
        # Use sha256sum -c for standard checksum files
        if $cmd_prefix sha256sum -c --ignore-missing < "$tmp" 2>/dev/null | grep -q "$(basename "$dest").*OK"; then
            echo "✓ Verified."
        else
            echo "✗ Verification failed!"
            $cmd_prefix rm -f "$dest"
            rm -f "$tmp"
            if [ "$fatal" = "true" ]; then
                exit 1
            else
                return 1
            fi
        fi
    fi
    
    rm -f "$tmp"
}

# ==============================================================================
# Step 0: Download Required Images (Talos ISO and Ubuntu Cloud Image)
# ==============================================================================
# Downloads and verifies:
#   - Talos metal ISO for Kubernetes nodes
#   - Ubuntu cloud image for HAProxy load balancer
# Both downloads include SHA256 checksum verification
# ==============================================================================

if [ "$SKIP_ISO_DOWNLOAD" = false ]; then
    cd "${VMS_DIR}"
    
    echo "==> Downloading standard Talos ISO..."
    download_and_verify \
        "Talos metal ISO" \
        "$TALOS_ISO_URL" \
        "$METALISO_ABSOLUTE_PATH" \
        "$TALOS_CHECKSUM_URL" \
        "" \
        "false" \
        "true"
    
    # Download Ubuntu Cloud Image for HAProxy
    download_and_verify \
        "Ubuntu cloud image" \
        "$UBUNTU_IMAGE_URL" \
        "$UBUNTU_IMAGE_PATH" \
        "$UBUNTU_CHECKSUM_URL" \
        "noble-server-cloudimg-amd64.img" \
        "true" \
        "false"

else
    echo "Skipping iso-download as requested."
fi

# ==============================================================================
# Step 1: Create VMs with Terraform
# ==============================================================================
# Uses Terraform to:
#   - Create libvirt VMs for control plane and worker nodes
#   - Create HAProxy load balancer VM
#   - Configure Cloudflare DNS records
#   - Attach Talos ISO to nodes for initial boot
# ==============================================================================

if [ "$SKIP_TERRAFORM" = false ]; then
    # Temporarily disable pipefail to avoid SIGPIPE from head
    set +o pipefail
    BRIDGE_NAME=$(ip -o link show type bridge | awk -F': ' '{print $2}' | head -n 1)
    set -o pipefail
    if [ -z "$BRIDGE_NAME" ]; then
        echo "No bridge interface found. Please create one and try again."
        exit 1
    fi

    cd "${VMS_DIR}"
    
    echo "Found bridge interface: $BRIDGE_NAME"
    export TF_VAR_bridge_name=$BRIDGE_NAME

    # Initialize and apply Terraform cloudflare configuration
    echo "Initializing and applying Terraform Cloudflare configuration."
    
    terraform init -input=false
    if ! terraform apply; then
        echo "Terraform apply failed."
        echo "cleaning up created VMs..."
        terraform destroy
        exit 1
    fi
    
    # Verify VMs were actually created
    echo "Verifying VMs were created..."
    EXPECTED_NODES=$(yq e '.nodes[] | .name' "$NODES_FILE_PATH" | wc -l)
    CREATED_VMS=$($SUDO virsh list --all | grep -E "control-node|worker-node|haproxy" | wc -l)
    
    if [ "$CREATED_VMS" -ne "$EXPECTED_NODES" ]; then
        echo "WARNING: Expected $EXPECTED_NODES VMs but found $CREATED_VMS. Some VMs may not have been created."
    else
        echo "✓ All $CREATED_VMS VMs created successfully."
    fi
    
    echo "Terraform applied successfully."
fi

# ==============================================================================
# Step 2: Setup and Pre-flight Checks
# ==============================================================================
# Prepare for cluster bootstrapping:
#   - Install required tools (talosctl, yq, jq, arp-scan)
#   - Create cluster directory
#   - Extract configuration from Terraform output
# ==============================================================================

# talosctl configuration

# Create cluster directory if it doesn't exist
if [ ! -d "$CLUSTER_DIR" ]; then
    echo "Cluster directory '$CLUSTER_DIR' does not exist. Creating it."
    mkdir -p "$CLUSTER_DIR"
fi

cd "${CLUSTER_DIR}"

# Check if talosctl is installed, if not, install it
if ! command -v talosctl &> /dev/null; then
    echo "Installing talosctl..."
    curl -sL https://talos.dev/install | sh
fi

# ==============================================================================
# Helper Function: Generate Node-Specific Configuration Patches
# ==============================================================================
# Creates network configuration patches for each node based on nodes.yaml
#
# This function:
#   1. Reads node definitions from nodes.yaml (by role)
#   2. Gets MAC addresses from Terraform output
#   3. Creates patch files with static network config
#   4. Applies patches to base configs to create node-specific configs
#
# Parameters:
#   $1 role - Node role to process ("control-node" or "worker-node")
#
# Generated files:
#   - ./node-configs/{name}-network-patch.yaml (temporary patch file)
#   - ./{name}-patched.yaml (final node-specific config)
# ==============================================================================

generate_patch_files_by_role() {
    local role=$1
    
    # necessary to write it like that because EOF isnt working any other way!
    # Create schematic YAML defining required extensions
    local schematic_id=$(curl -sX POST "https://factory.talos.dev/schematics" \
        -H "Content-Type: application/yaml" \
        --data-binary @- <<'EOF' | jq -r '.id'
customization:
    systemExtensions:
        officialExtensions:
        - siderolabs/qemu-guest-agent
        - siderolabs/amd-ucode
        - siderolabs/util-linux-tools
        - siderolabs/iscsi-tools
EOF
)
    if [ -z "$schematic_id" ] || [ "$schematic_id" == "null" ]; then
        echo "Error: Could not create Talos schematic for custom ISO." >&2
        exit 1
    fi

    echo -e "\nCreating configurations for ${role}s:"
    
    # Read nodes from YAML, convert to JSON for easier parsing
    while read -r node_json; do
        local name ip gateway mac
        
        # Extract node properties from JSON
        name=$(echo "$node_json" | jq -r '.name')
        ip=$(echo "$node_json" | jq -r '.ip')
        gateway=$(echo "$node_json" | jq -r '.gateway')
        # Get MAC address from Terraform output (needed for hardware selector)
        mac=$(cd "$VMS_DIR" && terraform output -json | jq -r --arg NAME "$name" \
            '.node_macs.value | to_entries[] | select(.key==$NAME) | .value | ascii_downcase')
        
        local patch_file="./node-configs/${name}-network-patch.yaml"
        echo "  ✓ ${name} network patch → ${patch_file}"

        local template_file base_config
        if [ "$role" == "control-node" ]; then
            template_file="$pwd/templates/control-node-patch.yaml"
            base_config="controlplane.yaml"
        else
            template_file="$pwd/templates/worker-node-patch.yaml"
            base_config="worker.yaml"
        fi

        # Export variables for yq to use in YAML generation
        # envsubst will replace string placeholders like ${NODE_NAME}.
        export SCHEMATIC_ID="$schematic_id"
        export NODE_NAME="$name"
        export IP="$ip"
        export GATEWAY="$gateway"
        export MAC="$mac"

        # Export the nameservers as a JSON array string.
        # The outer quotes are crucial to assign the whole array as one variable.
        export NAMESERVERS_ARRAY="$(echo "$node_json" | jq '.nameservers')"

        # This command performs two actions:
        # 1. `(.. | select(tag == "!!str")) |= envsubst`: Replaces all string
        #    placeholders like `${IP}` and `${MAC}`. This will also incorrectly
        #    turn `nameservers: ${NAMESERVERS_ARRAY}` into a string.
        # 2. `... | .machine.network.nameservers = ...`: This second part FIXES the nameservers
        #    field by overwriting it with a properly parsed and formatted block-style array.
        yq '(.. | select(tag == "!!str")) |= envsubst | 
            .machine.network.nameservers = (env(NAMESERVERS_ARRAY) | .. style="")' \
          "$template_file" > "$patch_file"
                        
        # Apply patch
        talosctl machineconfig patch "$base_config" --patch @"$patch_file" --output "$name-patched.yaml"
    done < <(yq e ".nodes[] | select(.role == \"${role}\")" "$NODES_FILE_PATH" -o=json -I=0 | jq -c '.')
}

# ==============================================================================
# Main Script Execution
# ==============================================================================

echo "==> Step 2a: Performing pre-flight checks..."

# Install required command-line tools if not already present
# - yq: YAML processor for reading nodes.yaml
# - jq: JSON processor for parsing Terraform output
# - curl: HTTP client for downloads
# - arp-scan: Network scanner for discovering node IPs
if ! command -v yq &> /dev/null; then echo "yq not found, installing..."; $SUDO apt-get update && $SUDO apt-get install -y yq; fi
if ! command -v jq &> /dev/null; then echo "jq not found, installing..."; $SUDO apt-get update && $SUDO apt-get install -y jq; fi
if ! command -v curl &> /dev/null; then echo "curl not found, installing..."; $SUDO apt-get update && $SUDO apt-get install -y curl; fi
if ! command -v $SUDO arp-scan $> /dev/null; then echo "arp-scan not found, installing..."; $SUDO apt-get update && $SUDO apt-get install -y arp-scan; fi

cd "$CLUSTER_DIR"

# ==============================================================================
# Step 3: Generate Talos Secrets and Machine Configurations
# ==============================================================================
# Generate:
#   - Secrets bundle (certificates, tokens, keys)
#   - Base machine configs for control plane and workers
#   - Configure Kubernetes API endpoint (HAProxy IP)
# Only run if NOT skipping config creation
# ==============================================================================

if [ "$SKIP_CONFIG_CREATION" = false ]; then
    echo "==> Step 2b: Detecting install disk from VM configuration..."

    # Get the actual disk device from a control node VM
    # This ensures we use the correct disk path that libvirt configured
    # Temporarily disable pipefail to avoid SIGPIPE errors from head
    set +o pipefail
    FIRST_CONTROL_NODE=$(yq e '.nodes[] | select(.role == "control-node") | .name' "$NODES_FILE_PATH" | head -1)
    DISK_TARGET=$($SUDO virsh domblklist "$FIRST_CONTROL_NODE" 2>/dev/null | grep -v "^$" | tail -n +3 | grep -v ".iso" | awk '{print $1}' | head -1)
    set -o pipefail

    if [ -z "$DISK_TARGET" ]; then
        echo "Warning: Could not detect disk from VM, using default /dev/vda"
        INSTALL_DISK="/dev/vda"
    else
        # virsh shows the target (e.g., 'vda'), we need full path
        INSTALL_DISK="/dev/${DISK_TARGET}"
        echo "Detected install disk from VM: ${INSTALL_DISK}"
    fi

    echo "Note: Talos will auto-detect the first disk as /dev/sda or /dev/vda during installation"
    echo ""
    
    # Continue with config generation below...
    echo -e "\n==> Step 3a: Generating secrets bundle..."
    if [ ! -f "secrets.yaml" ]; then
        talosctl gen secrets --output-file secrets.yaml
    else
        echo "Secrets bundle 'secrets.yaml' already exists."
    fi

    echo -e "\n==> Step 3b: Reading HAProxy IP for Kubernetes endpoint..."
    HAPROXY_IP=$(yq e '.nodes[] | select(.name == "haproxy") | .ip' "$NODES_FILE_PATH")
    if [ -z "$HAPROXY_IP" ]; then
        echo "Error: Could not find HAProxy IP in $NODES_FILE_PATH" >&2
        exit 1
    fi
    K8S_ENDPOINT="https://${HAPROXY_IP}:6443"
    echo "Kubernetes endpoint will be: ${K8S_ENDPOINT}"

    echo -e "\n==> Step 3c: Generating machine configurations..."

    if [ -f "controlplane.yaml" ] || [ -f "worker.yaml" ]; then
        echo "⚠ Warning: Machine configurations already exist!"
        echo "  This will regenerate configs and may break access to existing cluster."
        read -p "Do you want to overwrite them? (yes/no): " -r
        echo
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "Skipping config generation. Using existing configs."
        else
            echo "Regenerating configs..."
            rm -f controlplane.yaml worker.yaml 2>/dev/null
            talosctl gen config "$CLUSTER_NAME" "$K8S_ENDPOINT" --output-dir . --with-secrets ./secrets.yaml --install-disk "$INSTALL_DISK" --force
            echo "  ✓ Generated 'controlplane.yaml' and 'worker.yaml' with install disk: $INSTALL_DISK"
        fi
    else
        # First time generation
        talosctl gen config "$CLUSTER_NAME" "$K8S_ENDPOINT" --output-dir . --with-secrets ./secrets.yaml --install-disk "$INSTALL_DISK" --force
        echo "  ✓ Generated 'controlplane.yaml' and 'worker.yaml' with install disk: $INSTALL_DISK"
    fi
else
    echo -e "\n==> Step 3: Skipping config generation (--skip-config-creation flag set)"
    echo "Using existing configs. Make sure you have:"
    echo "  - secrets.yaml"
    echo "  - controlplane.yaml and worker.yaml"
    
    # Still need to read HAProxy IP for later steps
    HAPROXY_IP=$(yq e '.nodes[] | select(.name == "haproxy") | .ip' "$NODES_FILE_PATH")
    K8S_ENDPOINT="https://${HAPROXY_IP}:6443"
    INSTALL_DISK="/dev/vda"  # Default, won't be used for generation
fi

# ==============================================================================
# Step 4: Wait for VMs to Boot from ISO
# ==============================================================================
# At this point:
#   - VMs have been created by Terraform with ISO attached
#   - Nodes are booting from the Talos ISO (live environment)
#   - Network interfaces will get DHCP IPs from the router
#   - Static IPs are NOT configured yet (they're in the machine config)
#
# Generate machine configs for each node with:
#   - Static IP addresses
#   - Hostname
#   - Network configuration
#   - Node-specific patches
# These configs will be applied to nodes running on DHCP IPs
# ==============================================================================

echo -e "\n==> Step 4-5: Generating node-specific configurations..."
cd "$CLUSTER_DIR"
mkdir -p ./node-configs

if [ "$SKIP_CONFIG_CREATION" = true ]; then
    echo "Skipping node-specific config generation (--skip-config-creation flag set)."
else
    CONTROL_NODE_COUNT=$(yq e '[.nodes[] | select(.role == "control-node")] | length' "$NODES_FILE_PATH")
    WORKER_NODE_COUNT=$(yq e '[.nodes[] | select(.role == "worker-node")] | length' "$NODES_FILE_PATH")
    echo "Found ${CONTROL_NODE_COUNT} control node(s) and ${WORKER_NODE_COUNT} worker node(s)."

    # Use the new helper function to create patch files.
    generate_patch_files_by_role "control-node"
    generate_patch_files_by_role "worker-node"
fi

# ==============================================================================
# Steps 6-9: Bootstrap Process
# ==============================================================================
# Only run if NOT skipping bootstrap
# ==============================================================================

if [ "$SKIP_BOOTSTRAP" = false ]; then

echo -e "\n==> Continuing with node installation and bootstrap..."

# ==============================================================================
# Step 6: Discover Dynamic IPs and Apply Configurations
# ==============================================================================
# Workflow:
#   1. Discover nodes via arp-scan (they have DHCP IPs now)
#   2. Match MAC addresses from Terraform to discovered IPs
#   3. Eject ISO from all nodes
#   4. Apply machine configs to dynamic IPs with --mode=reboot
#   5. Nodes reboot and boot from disk with static IPs configured
# ==============================================================================

echo -e "\n==> Step 6: Verifying HAProxy is ready..."

# Check if HAProxy is accessible before proceeding with control nodes
HAPROXY_IP=$(yq e '.nodes[] | select(.name == "haproxy") | .ip' "$NODES_FILE_PATH")
echo "Checking HAProxy at ${HAPROXY_IP}:6443..."

RETRY=0
MAX_RETRY=36  # 6 minutes max (36 * 10s)
HAPROXY_READY=false

while [ $RETRY -lt $MAX_RETRY ]; do
    if nc -z -w 5 "$HAPROXY_IP" 6443 2>/dev/null || timeout 5 bash -c "echo > /dev/tcp/${HAPROXY_IP}/6443" 2>/dev/null; then
        echo "✓ HAProxy is listening on port 6443"
        HAPROXY_READY=true
        break
    fi
    
    if [ $RETRY -eq 0 ]; then
        echo -n "Waiting for HAProxy to become ready"
    fi
    
    # Show progress every 5 attempts (50 seconds)
    if [ $((RETRY % 5)) -eq 0 ] && [ $RETRY -gt 0 ]; then
        echo -n " [${RETRY}0s]"
    else
        echo -n "."
    fi
    
    sleep 10
    RETRY=$((RETRY+1))
done

if [ "$HAPROXY_READY" = false ]; then
    echo ""
    echo "⚠ Warning: HAProxy not responding on port 6443 after 6 minutes"
    echo "  Continuing anyway - HAProxy will be needed once control plane starts"
    echo "  You may need to check HAProxy logs: ssh ubuntu@${HAPROXY_IP}"
else
    if [ $RETRY -gt 0 ]; then
        echo ""
    fi
fi

echo -e "\n==> Step 7: Applying configurations to nodes..."

# Define retry function for config application
apply_config_with_retry() {
  local node_name=$1
  local node_ip=$2
  local config_file=$3
  local max_attempts=3
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    # Apply config WITH --mode=reboot so Talos handles the reboot properly
    if talosctl -n "$node_ip" apply-config --insecure --file "$config_file" --mode=reboot 2>&1 | grep -q "applied"; then
      return 0
    fi
    
    attempt=$((attempt + 1))
    if [ $attempt -le $max_attempts ]; then
      sleep 5
    fi
  done
  
  return 1
}

cd "$VMS_DIR"

# Discovery parameters
RETRY_COUNT=0
MAX_RETRIES=24  # 24 * 5s = 2 minutes max wait
RETRY_DELAY=5
DYNAMIC_IPS=""
EXPECTED_NODE_COUNT=$(yq e '[.nodes[] | select(.role != "haproxy")] | length' "$NODES_FILE_PATH")

# Discover nodes by matching MAC addresses (from Terraform) to IPs (from arp-scan)
echo "Discovering node IPs with arp-scan..."
echo "Looking for ${EXPECTED_NODE_COUNT} Talos nodes with DHCP-assigned IPs..."

while [ -z "$DYNAMIC_IPS" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  # Run the discovery command
  DISCOVERED_IPS=$(join -1 1 -2 1 -o 1.2,2.2 \
      <(terraform output -json | jq -r '.node_macs.value | to_entries[] | "\(.value | ascii_downcase) \(.key)"' | sort -k1,1) \
      <(sudo arp-scan --interface=br0 --localnet | awk '/:/ {print $2, $1}' | sort -k1,1))

  if [ -n "$DISCOVERED_IPS" ]; then
      # Verify at least one node is actually ready (Talos API responding)
      NODE_READY=false
      echo "$DISCOVERED_IPS" | while read -r name ip; do
          if timeout 2 talosctl -n "$ip" version --insecure &>/dev/null; then
              NODE_READY=true
              break
          fi
      done 2>/dev/null
      
      # If we have IPs and at least one responds, we're good
      FOUND_COUNT=$(echo "$DISCOVERED_IPS" | wc -l)
      if [ "$FOUND_COUNT" -ge "$EXPECTED_NODE_COUNT" ]; then
          DYNAMIC_IPS="$DISCOVERED_IPS"
          break
      fi
  fi

  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $((RETRY_COUNT % 4)) -eq 0 ]; then
      echo "  [${RETRY_COUNT}×${RETRY_DELAY}s] Still waiting for nodes to boot..."
  else
      echo -n "."
  fi
  sleep $RETRY_DELAY
done

if [ $((RETRY_COUNT % 4)) -ne 0 ] && [ $RETRY_COUNT -gt 0 ]; then
  echo ""
fi

# Fail if no nodes are found after all retries
if [ -z "$DYNAMIC_IPS" ]; then
  echo "Error: Failed to discover any node IPs with arp-scan after $((MAX_RETRIES * RETRY_DELAY))s." >&2
  echo "--- Diagnostics ---"
  echo "VM Status:"
  virsh list --all
  echo "-------------------"
  echo "arp-scan raw output:"
  sudo arp-scan --interface=br0 --localnet
  echo "-------------------"
  exit 1
fi

FOUND_COUNT=$(echo "$DYNAMIC_IPS" | wc -l)
echo "✓ Successfully discovered ${FOUND_COUNT}/${EXPECTED_NODE_COUNT} nodes"
echo "$DYNAMIC_IPS" | while read -r name ip; do
  echo "  • $name → $ip"
done

# Change back to cluster directory where the patched configs are located
cd "$CLUSTER_DIR"

# Export TALOSCONFIG for all subsequent talosctl commands
export TALOSCONFIG="$CLUSTER_DIR/talosconfig"
echo "Using talosconfig: $TALOSCONFIG"

# Filter control and worker nodes from discovered IPs
CONTROL_IPS=$(echo "$DYNAMIC_IPS" | grep '^control-node' || true)
WORKER_IPS=$(echo "$DYNAMIC_IPS" | grep '^worker-node' || true)

# ==============================================================================
# Step 7: Install ALL nodes in parallel (control + workers)
# ==============================================================================
# Apply configurations to all nodes simultaneously for faster installation
# Then wait only for first control node to be ready before bootstrapping
# Workers will join the cluster automatically after bootstrap completes
# ==============================================================================

echo -e "\n==> Step 7: Installing Talos on all nodes (parallel)..."

# Combine all node IPs for parallel installation
ALL_NODE_IPS=$(printf "%s\n%s" "$CONTROL_IPS" "$WORKER_IPS")

echo -e "\nApplying config to all nodes (control + workers) in parallel:"

if [ -z "$ALL_NODE_IPS" ]; then
  echo "ERROR: No nodes found in discovered IPs!" >&2
  exit 1
fi

TOTAL_NODES=$(echo "$ALL_NODE_IPS" | wc -l)
echo "Processing ${TOTAL_NODES} node(s) total..."

# Phase 7.1: Apply configs to ALL nodes in parallel
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 7.1: Applying configurations to all nodes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NODE_NUMBER=1
FAILED_NODES=""

echo "$ALL_NODE_IPS" | while read -r name dyn_ip; do
  echo "[${NODE_NUMBER}/${TOTAL_NODES}] Applying config to ${name} (${dyn_ip})..."
  (
    if ! apply_config_with_retry "$name" "$dyn_ip" "./${name}-patched.yaml"; then
      echo "$name" >> /tmp/failed_nodes_$$
    fi
  ) &
  NODE_NUMBER=$((NODE_NUMBER + 1))
done

# Wait for all background jobs to complete
wait

# Check for failures
if [ -f /tmp/failed_nodes_$$ ]; then
  FAILED_NODES=$(cat /tmp/failed_nodes_$$)
  rm -f /tmp/failed_nodes_$$
  echo "⚠ Warning: Some nodes failed to apply config: $FAILED_NODES"
  echo "Continuing with remaining nodes..."
else
  echo "✓ All configs applied successfully"
fi

# Phase 7.2: Change boot order to disk-first (ISO remains attached as fallback)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 7.2: Setting boot order (disk first, cdrom fallback)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cd "$VMS_DIR"

# Process ALL nodes (both control and worker)
echo "$ALL_NODE_IPS" | while read -r name dyn_ip; do
  if [ -z "$name" ]; then
    continue
  fi
  
  echo "Setting boot order for: $name"
  
  # Use virt-xml to set boot order: disk first, cdrom second
  # This persists the change in the VM definition
  if $SUDO virt-xml "$name" --edit --boot hd,cdrom 2>&1 | sed 's/^/  /'; then
    echo "  ✓ Boot order updated for $name (disk->cdrom)"
  else
    echo "  ⚠ Warning: Failed to update boot order for $name"
  fi
done

cd "$CLUSTER_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Note: ISOs remain attached as fallback boot option"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "✓ All VMs now boot from disk first"

# Phase 7.3: Wait ONLY for first control node to be ready
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 7.3: Waiting for first control node to be ready"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get control plane static IPs
CONTROL_STATIC_IPS=$(yq e '.nodes[] | select(.role == "control-node") | .ip' "$NODES_FILE_PATH" | tr '\n' ' ')

echo "Configuring talosctl endpoints: $CONTROL_STATIC_IPS"
talosctl config endpoint $CONTROL_STATIC_IPS

FIRST_READY=""
MAX_WAIT=90
ELAPSED=0

echo "Checking for first ready control node..."
while [ -z "$FIRST_READY" ] && [ $ELAPSED -lt $MAX_WAIT ]; do
  for ip in $CONTROL_STATIC_IPS; do
    # Use authenticated connection
    if talosctl -n "$ip" version --client=false &>/dev/null; then
      FIRST_READY="$ip"
      echo ""
      echo "✓ First control node ready: $ip (${ELAPSED}s)"
      break
    fi
  done
  
  if [ -z "$FIRST_READY" ]; then
    if [ $((ELAPSED % 10)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
      echo -n " [${ELAPSED}s]"
    else
      echo -n "."
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
  fi
done

if [ -z "$FIRST_READY" ]; then
  echo ""
  echo "⚠ Warning: No control nodes ready after ${MAX_WAIT}s"
  echo "Cannot proceed with bootstrap. Check node status manually."
  exit 1
fi

echo "✓ Control plane is ready. Workers will join after bootstrap."

# Close the skip-bootstrap conditional that started at Step 2
else
    echo -e "\n==> Steps 2-7: Skipped (--skip-bootstrap enabled)"
    echo "Assuming cluster VMs are already configured and running."
    
    # Still need to set up essential variables for later steps
    cd "${CLUSTER_DIR}"
    
    # Get first control plane IP for kubeconfig retrieval
    set +o pipefail
    FIRST_CP_STATIC_IP=$(yq e '.nodes[] | select(.role == "control-node") | .ip' "$NODES_FILE_PATH" | head -1)
    set -o pipefail
    
    # Configure talosctl endpoints
    CONTROL_STATIC_IPS=$(yq e '.nodes[] | select(.role == "control-node") | .ip' "$NODES_FILE_PATH" | tr '\n' ' ')
    echo "Configuring talosctl endpoints: $CONTROL_STATIC_IPS"
    talosctl config endpoint $CONTROL_STATIC_IPS
    
    export TALOSCONFIG="$CLUSTER_DIR/talosconfig"
    echo "Using talosconfig: $TALOSCONFIG"
fi

# At this point, first control node is ready! Bootstrap immediately.

# ==============================================================================
# Step 8: Bootstrap Kubernetes Cluster
# ==============================================================================
# Initialize the Kubernetes cluster on the first control plane node
# This creates the etcd cluster and starts Kubernetes components
# ==============================================================================

if [ "$SKIP_BOOTSTRAP" = false ]; then
    echo -e "\n==> Step 8: Bootstrapping Kubernetes cluster..."

    # Temporarily disable pipefail to avoid SIGPIPE from head
    set +o pipefail
    FIRST_CP_STATIC_IP=$(yq e '.nodes[] | select(.role == "control-node") | .ip' "$NODES_FILE_PATH" | head -1)
    set -o pipefail

    echo "Bootstrapping on first ready node: ${FIRST_CP_STATIC_IP}"

    RETRY=0
    MAX_RETRY=3
    while [ $RETRY -lt $MAX_RETRY ]; do
        if talosctl -n "$FIRST_CP_STATIC_IP" bootstrap; then
            echo "✓ Bootstrap successful."
            break
        fi
        RETRY=$((RETRY+1))
        if [ $RETRY -lt $MAX_RETRY ]; then
            echo "! Bootstrap failed, retrying in 15s... (Attempt $RETRY/$MAX_RETRY)"
            sleep 15
        fi
    done

    if [ $RETRY -eq $MAX_RETRY ]; then
        echo "✗ Bootstrap failed after $MAX_RETRY attempts. Cluster may already be bootstrapped or there's a critical issue."
        echo "  Try manually: talosctl -n $FIRST_CP_STATIC_IP bootstrap"
    else
        # Verify etcd is healthy after bootstrap
        echo "Verifying etcd cluster health..."
        sleep 10  # Give etcd a moment to stabilize
        if talosctl -n "$FIRST_CP_STATIC_IP" service etcd status 2>/dev/null | grep -q "Running"; then
            echo "✓ Etcd is running and healthy"
        else
            echo "⚠ Warning: Could not verify etcd status (may still be starting)"
        fi
    fi
else
    echo -e "\n==> Step 8: Skipping bootstrap as requested."
    echo "Cluster should already be bootstrapped."
    
    # First control plane IP should already be set from the else block above
    # But set it again if somehow needed
    if [ -z "$FIRST_CP_STATIC_IP" ]; then
        set +o pipefail
        FIRST_CP_STATIC_IP=$(yq e '.nodes[] | select(.role == "control-node") | .ip' "$NODES_FILE_PATH" | head -1)
        set -o pipefail
    fi
fi

# ==============================================================================
# Step 8a: Wait for Remaining Control Nodes to Join
# ==============================================================================
# Now that bootstrap is complete, wait for other control nodes to join etcd
# ==============================================================================

if [ "$SKIP_BOOTSTRAP" = false ]; then
  CONTROL_NODE_COUNT=$(yq e '[.nodes[] | select(.role == "control-node")] | length' "$NODES_FILE_PATH")
  if [ "$CONTROL_NODE_COUNT" -gt 1 ]; then
      echo -e "\n==> Step 8a: Waiting for remaining control nodes to join..."
      
      READY_NODES="$FIRST_CP_STATIC_IP"
      MAX_WAIT=90
      ELAPSED=0
      
      echo "Waiting for ${CONTROL_NODE_COUNT} control nodes to join etcd cluster..."
      while [ $(echo "$READY_NODES" | wc -w) -lt $CONTROL_NODE_COUNT ] && [ $ELAPSED -lt $MAX_WAIT ]; do
          for ip in $CONTROL_STATIC_IPS; do
              # Skip if already marked as ready
              if echo "$READY_NODES" | grep -q "$ip"; then
                  continue
              fi
              
              # Check if node is responsive
              if talosctl -n "$ip" version --client=false &>/dev/null; then
                  READY_NODES="$READY_NODES $ip"
                  READY_COUNT=$(echo "$READY_NODES" | wc -w)
                  echo "✓ Control node joined: $ip [${READY_COUNT}/${CONTROL_NODE_COUNT}]"
              fi
          done
          
          if [ $(echo "$READY_NODES" | wc -w) -lt $CONTROL_NODE_COUNT ]; then
              if [ $((ELAPSED % 10)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
                  echo -n " [${ELAPSED}s]"
              else
                  echo -n "."
              fi
              sleep 2
              ELAPSED=$((ELAPSED + 2))
          fi
      done
      
      FINAL_COUNT=$(echo "$READY_NODES" | wc -w)
      if [ $FINAL_COUNT -lt $CONTROL_NODE_COUNT ]; then
          echo ""
          echo "⚠ Warning: Only ${FINAL_COUNT}/${CONTROL_NODE_COUNT} control nodes joined after ${MAX_WAIT}s"
          echo "Check missing nodes with: talosctl -n <ip> get members --namespace=os"
      else
          echo ""
          echo "✓ All ${CONTROL_NODE_COUNT} control nodes have joined the cluster!"
      fi
  fi

  # ==============================================================================
  # Step 8b: Verify Worker Nodes
  # ==============================================================================
  # Wait for workers to come up and verify they're ready
  # Workers were installed in parallel during Step 7 and will join automatically
  # ==============================================================================

  if [ -n "$WORKER_IPS" ]; then
      echo -e "\n==> Step 8b: Waiting for worker nodes to be ready and verifying them..."

      # Get worker static IPs
      WORKER_STATIC_IPS=$(yq e '.nodes[] | select(.role == "worker-node") | .ip' "$NODES_FILE_PATH" | tr '\n' ' ')
      
      FIRST_WORKER_READY=""
      MAX_WAIT=90
      ELAPSED=0
      
      echo "Checking for first ready worker node..."
      while [ -z "$FIRST_WORKER_READY" ] && [ $ELAPSED -lt $MAX_WAIT ]; do
          for ip in $WORKER_STATIC_IPS; do
              # Use authenticated connection
              if talosctl -n "$ip" version --client=false &>/dev/null; then
                  FIRST_WORKER_READY="$ip"
                  echo ""
                  echo "✓ First worker node ready: $ip (${ELAPSED}s)"
                  break
              fi
          done
          
          if [ -z "$FIRST_WORKER_READY" ]; then
              if [ $((ELAPSED % 10)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
                  echo -n " [${ELAPSED}s]"
              else
                  echo -n "."
              fi
              sleep 2
              ELAPSED=$((ELAPSED + 2))
          fi
      done
      
      if [ -z "$FIRST_WORKER_READY" ]; then
          echo ""
          echo "⚠ Warning: No worker nodes ready after ${MAX_WAIT}s"
          echo "Workers may still be booting or joining. Check manually with: kubectl get nodes"
      else
          echo "✓ Worker nodes are ready and will join the cluster"
      fi
  else
      echo -e "\n⚠ No worker nodes found to verify"
  fi
else
  echo -e "\n==> Steps 8a-8b: Skipping node join verification (--skip-bootstrap enabled)"
fi

# ==============================================================================
# Step 9: Retrieve Kubeconfig and Finale!
# ==============================================================================
# Wait for Kubernetes API server to be ready
# Retrieve and save kubeconfig for kubectl access
# ==============================================================================

if [ "$SKIP_BOOTSTRAP" = false ]; then
  echo -e "\n==> Step 9: Retrieving kubeconfig..."
  cd $pwd

  echo "Waiting for Kubernetes API to be ready..."

  RETRY=0
  MAX_RETRY=20
  while [ $RETRY -lt $MAX_RETRY ]; do
      if talosctl -n "$FIRST_CP_STATIC_IP" kubeconfig --force 2>/dev/null; then
          echo "✓ Kubeconfig retrieved successfully."
          break
      fi
      RETRY=$((RETRY+1))
      if [ $RETRY -lt $MAX_RETRY ]; then
          echo -n "."
          sleep 10
      fi
  done

  if [ $RETRY -eq $MAX_RETRY ]; then
      echo "\n✗ Failed to retrieve kubeconfig after $((MAX_RETRY * 10))s."
      echo "  The cluster may still be initializing. Try later: talosctl -n $FIRST_CP_STATIC_IP kubeconfig"
  fi
else
  echo -e "\n==> Step 9: Skipping kubeconfig retrieval (--skip-bootstrap enabled)"
fi

# ==============================================================================
# Step 10: Install Cilium CNI with KubePrism
# ==============================================================================
# Install Cilium using Talos's built-in KubePrism load balancer
# This avoids certificate issues and provides optimal performance
# ==============================================================================

if [ "$SKIP_CILIUM_INSTALLATION" = false ]; then
  echo -e "\n==> Step 10: Installing Cilium CNI with KubePrism..."

  # Wait for Kubernetes API to be fully ready
  echo "Waiting for Kubernetes API to be fully ready..."
  RETRY=0
  MAX_RETRY=60  # 10 minutes max
  API_READY=false
  
  while [ $RETRY -lt $MAX_RETRY ]; do
      # Try to list nodes - this confirms API server is responding
      if kubectl get nodes &>/dev/null; then
          API_READY=true
          echo ""
          echo "✓ Kubernetes API is ready (${RETRY}0s)"
          break
      fi
      
      if [ $RETRY -eq 0 ]; then
          echo -n "Waiting for API server to be ready"
      fi
      
      # Show progress every 3 attempts (30 seconds)
      if [ $((RETRY % 3)) -eq 0 ] && [ $RETRY -gt 0 ]; then
          echo -n " [${RETRY}0s]"
      else
          echo -n "."
      fi
      
      sleep 10
      RETRY=$((RETRY+1))
  done
  
  if [ "$API_READY" = false ]; then
      echo ""
      echo "⚠ Warning: Kubernetes API still not ready after $((MAX_RETRY * 10))s"
      echo "  Cannot install Cilium. Check cluster status:"
      echo "  - talosctl -n $FIRST_CP_STATIC_IP service kubelet status"
      echo "  - talosctl -n $FIRST_CP_STATIC_IP service etcd status"
      exit 1
  fi

  # Check if cilium CLI is available
  if ! command -v cilium &> /dev/null; then
      echo "Installing Cilium CLI..."
      CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
      CLI_ARCH=amd64
      if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
      curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
      sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
      $SUDO tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
      rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
      echo "✓ Cilium CLI installed"
  fi

  # Clean up any existing Cilium installation
  echo "Checking for existing Cilium resources..."
  if kubectl get ns cilium &>/dev/null 2>&1; then
      echo "Found existing Cilium, removing..."
      
      # Remove Helm release if it exists
      helm uninstall cilium -n cilium --no-hooks 2>/dev/null || true
      
      # Force cleanup with cilium CLI (30s timeout)
      timeout 30 cilium uninstall 2>/dev/null || echo "Cilium CLI cleanup completed"
      
      # Force delete namespaces
      kubectl delete ns cilium cilium-test --grace-period=0 --force 2>/dev/null || true
      
      echo "Cleanup complete, waiting 5s..."
      sleep 5
  else
      echo "No existing Cilium installation found."
  fi
  
  # Create cilium namespace with Helm labels and annotations (idempotent)
  kubectl create namespace cilium --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace cilium app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace cilium meta.helm.sh/release-name=cilium meta.helm.sh/release-namespace=cilium --overwrite

  # kubeprism! port 7445
  # Install Cilium with KubePrism configuration
  echo "Installing Cilium with KubePrism (127.0.0.1:7445)..."
  cilium install \
      --version 1.18.2 \
      --namespace cilium \
      --set ipam.mode=kubernetes \
      --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
      --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
      --set cgroup.autoMount.enabled=false \
      --set cgroup.hostRoot=/sys/fs/cgroup \
      --set kubeProxyReplacement=true \
      --set k8sServiceHost=localhost \
      --set k8sServicePort=7445 \
      --set envoy.enabled=true \
      --set envoyConfig.enabled=true \
      --set envoyConfig.secretsNamespace.name=cilium \
      --set gatewayAPI.enabled=true \
      --set gatewayAPI.secretsNamespace.name=cilium \
      --set gatewayAPI.enableAlpn=true \
      --set gatewayAPI.enableAppProtocol=true\
      --set sysctlfix.enabled=false \
      --set externalIPs.enabled=true \
      --set installCRDs=true \
      --set l2announcements.enabled=true \
      --set loadBalancer.l7.backend=envoy \
      --set hubble.enabled=false
  # Wait for Cilium to be ready
  echo "Waiting for Cilium to be ready..."
  RETRY=0
  MAX_RETRY=30
  while [ $RETRY -lt $MAX_RETRY ]; do
      # Just check if cilium pods are running
      if kubectl get pods -n cilium -l app.kubernetes.io/name=cilium-agent -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q "Running"; then
          echo ""
          echo "✓ Cilium is ready (${RETRY}0s)"
          break
      fi
      
      if [ $RETRY -eq 0 ]; then
          echo -n "Checking Cilium pods"
      fi
      
      if [ $((RETRY % 3)) -eq 0 ] && [ $RETRY -gt 0 ]; then
          echo -n " [${RETRY}0s]"
      else
          echo -n "."
      fi
      
      sleep 10
      RETRY=$((RETRY+1))
  done

  if [ $RETRY -eq $MAX_RETRY ]; then
      echo ""
      echo "⚠ Warning: Cilium may still be initializing after $((MAX_RETRY * 10))s"
      echo "  Check status with: cilium status"
  else
      # Show Cilium status
      echo ""
      cilium status 2>/dev/null || echo "  Note: Run 'cilium status' to verify installation"
  fi
else
  echo -e "\n==> Step 10: Skipping Cilium installation as requested."
fi

# ==============================================================================
# Step 11: Install ArgoCD
# ==============================================================================
# Install ArgoCD for GitOps-based application deployment
# Uses HA manifests and installs Gateway API CRDs
# ==============================================================================

if [ "$SKIP_ARGOCD_INSTALLATION" = false ]; then
  echo -e "\n==> Step 11: Installing ArgoCD..."
  
  # Wait for cluster to be ready
  echo "Waiting for cluster to be ready..."
  kubectl wait --for=condition=Ready nodes --all --timeout=300s 2>/dev/null || echo "⚠ Nodes may still be initializing"
  
  # Install ArgoCD namespace
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  
  # Install ArgoCD HA components
  echo "Installing ArgoCD (HA mode)..."
  kubectl -n argocd apply -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.0.19/manifests/ha/namespace-install.yaml
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.0.19/manifests/ha/install.yaml

  
  # Install Gateway API CRDs
  echo "Installing Gateway API CRDs..."
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml
  
  # Wait for ArgoCD server to be ready
  echo "Waiting for ArgoCD server to be ready..."
  kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s || echo "⚠ ArgoCD may still be starting"
  
  # Get initial admin password
  ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
  
  echo ""
  echo "✓ ArgoCD installed successfully!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 ArgoCD Access Information:"
  echo "   • Username: admin"
  if [ -n "$ARGOCD_PASSWORD" ]; then
      echo "   • Password: $ARGOCD_PASSWORD"
  else
      echo "   • Password: Run 'kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d'"
  fi
  echo "   • Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443"
  echo "   • Access at: https://localhost:8080"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Optional: Apply deployment.yml if it exists
  if [ -f "${pwd}/argocd/deployment.yml" ]; then
      echo "Found argocd/deployment.yml - would you like to apply it? (requires GitHub credentials)"
      echo "This will set up the ArgoCD Application for GitOps."
      echo "Note: You'll need to create the GitHub secret manually first."
      echo ""
      echo "To apply later, run:"
      echo "  kubectl apply -f argocd/deployment.yml"
  fi
else
  echo -e "\n==> Step 11: Skipping ArgoCD installation as requested."
fi

# ==============================================================================
# 12: Install FluxCD
# ==============================================================================
if [ "$SKIP_FLUXCD_INSTALLATION" = false ]; then

  echo -e "\n==> Step 12: Installing FluxCD ..."
  # Wait for cluster to be ready
  echo "Waiting for cluster to be ready..."
  kubectl wait --for=condition=Ready nodes --all --timeout=300s 2>/dev/null || echo "⚠ Nodes may still be initializing"

  # Install kubectl if not present
  echo "Checking if kubectl is installed..."
  if [ kubectl version ]; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
  fi
  
  echo "Creating namespaces for cert-manager and external-dns..."

  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -

  echo "Create secrets for cert-manager and external-dns..."
  kubectl create secret generic cloudflare-token -n cert-manager --from-literal=token=$CLOUDFLARE_TOKEN --dry-run=client -o yaml | kubectl apply -f -
  
  kubectl create secret generic pihole -n external-dns --from-literal=EXTERNAL_DNS_PIHOLE_PASSWORD=$PIHOLE_PASSWORD --from-literal=EXTERNAL_DNS_PIHOLE_SERVER=$PIHOLE_SERVER --from-literal=EXTERNAL_DNS_PIHOLE_API_VERSION="6" --dry-run=client -o yaml | kubectl apply -f -

  # Install flux CLI if not present
  echo "Checking if FluxCD CLI is installed..."
  if ! command -v flux &> /dev/null; then
    echo "Installing FluxCD CLI..."
    curl -s https://fluxcd.io/install.sh | sudo bash
  else
    echo "FluxCD CLI already installed."
  fi

  RETRIES=3
  SLEEP_INTERVAL=15
  COUNTER=0

  while [[ $COUNTER -lt $RETRIES ]]; do
    echo "Checking Flux GitRepository reconciliation status..."
    STATUS=$(kubectl -n flux-system get gitrepositories.source.toolkit.fluxcd.io flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")

    if [[ "$STATUS" == "True" ]]; then
      echo "Flux GitRepository reconciled successfully."
      break
    else
      echo "Flux GitRepository not reconciled yet. Attempt $((COUNTER+1)) of $RETRIES."
      ((COUNTER++))
      sleep $SLEEP_INTERVAL
    fi
  done

  if [[ "$STATUS" != "True" ]]; then
    echo "GitRepository failed to reconcile after $RETRIES attempts. Cleaning up and retrying bootstrap..."

    # Delete gitrepository and secrets to force refresh
    kubectl -n flux-system delete gitrepositories.source.toolkit.fluxcd.io flux-system
    kubectl -n flux-system delete secret flux-system

    echo "Re-running Flux bootstrap..."
    flux bootstrap github \
      --token-auth \
      --owner=$GITHUB_REPO_OWNER \
      --repository=$GITHUB_REPO \
      --branch=main \
      --path=clusters \
      --personal \
      --private=true
  fi
  
  echo ""
  echo "✓ FluxCD repo ${GITHUB_REPO_OWNER}/${GITHUB_REPO} deployed successfully!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo -e "\n==> Step 12: Skipping FluxCD installation as requested."
fi

# ==============================================================================
# Cleanup temporary files
# ==============================================================================

if [ "$SKIP_BOOTSTRAP" = false ]; then
  echo -e "\n==> Cleaning up temporary files..."
  cd "$CLUSTER_DIR"

  # Remove temporary directories
  if [ -d "./node-configs" ]; then
    rm -rf ./node-configs
    echo "  ✓ Removed node-configs/"
  fi

  echo "  ✓ Kept: talosconfig, secrets.yaml, controlplane.yaml, worker.yaml and *-patched.yaml files"
fi

# ==============================================================================
# Final Summary
# ==============================================================================

echo -e "\n✅ Cluster setup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Cluster Summary:"
if [ "$SKIP_BOOTSTRAP" = false ]; then
  echo "   • Control nodes: ${CONTROL_NODE_COUNT}"
  echo "   • Worker nodes: ${WORKER_NODE_COUNT}"
  echo "   • Kubernetes endpoint: ${K8S_ENDPOINT}"
fi
if [ "$SKIP_CILIUM_INSTALLATION" = false ]; then
  echo "   • CNI: Cilium with KubePrism (127.0.0.1:7445)"
fi
if [ "$SKIP_ARGOCD_INSTALLATION" = false ]; then
  echo "   • GitOps: ArgoCD (HA mode)"
fi
if [ "$SKIP_FLUXCD_INSTALLATION" = false ]; then
  echo "   • GitOps: FluxCD Setup (GitHub repo: $GITHUB_REPO_OWNER/$GITHUB_REPO)"
fi
if [ "$SKIP_BOOTSTRAP" = false ]; then
  echo "   • Kubeconfig Location: $(pwd)/kubeconfig"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "To verify your cluster, run:"
if [ "$SKIP_BOOTSTRAP" = false ]; then
    echo "  kubectl get nodes"
fi
if [ "$SKIP_CILIUM_INSTALLATION" = false ]; then
    echo "  cilium status"
fi
if [ "$SKIP_ARGOCD_INSTALLATION" = false ]; then
    echo "  kubectl get pods -n argocd"
fi
echo "k get pods -A"

# ==============================================================================
# Disable cleanup trap on successful completion
# ==============================================================================
# Script completed successfully, so disable the error cleanup trap

CLEANUP_ON_ERROR=false
