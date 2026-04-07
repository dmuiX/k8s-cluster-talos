#!/bin/bash

# --- Talos Kubernetes Cluster Bootstrap Script ---
# This script automates the complete setup of a Talos Linux Kubernetes cluster
# on KVM/libvirt with HAProxy load balancer and Cloudflare DNS.
#
# Prerequisites:
#   - KVM/libvirt installed and running
#   - Bridge network configured (e.g., br0)
#   - Cloudflare account with API token (optional, use --skip-cloudflare to skip)
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
#     --skip-init-openbao  Skip initializing OpenBao
#     --skip-cloudflare       Skip Cloudflare DNS record creation
#     --debug                 Enable verbose bash debug mode (set -x)
#     --no-cleanup            Disable automatic terraform destroy on error
#     --cleanup-vms           Destroy only VMs (keeps Cloudflare DNS records)
#     --cleanup-all           Complete cleanup: VMs + DNS (terraform destroy)
#

set -eu  # Exit on error, undefined vars. pipefail is debug-only (see --debug handling).

# --- Versions ---
CILIUM_VERSION="1.19.2"
GATEWAY_API_VERSION="v1.4.0"

# --- Help Function ---
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Talos Kubernetes Cluster Bootstrap Script
Automates the complete setup of a Talos Linux Kubernetes cluster on KVM/libvirt.

OPTIONS:
    -h, --help                  Show this help message and exit
    --skip-iso-download         Skip downloading Talos ISO and Ubuntu image
    --skip-terraform            Skip VM creation (use existing VMs)
    --skip-config-creation      Skip generating Talos configs (use existing configs)
    --skip-bootstrap            Skip cluster bootstrap (use existing cluster)
    --skip-cilium-installation  Skip Cilium CNI installation
    --skip-argocd-installation  Skip ArgoCD installation
    --skip-fluxcd-installation  Skip FluxCD installation
    --skip-init-openbao         Skip initializing OpenBao
    --skip-cloudflare           Skip Cloudflare DNS record creation
    --debug                     Enable verbose bash debug mode (set -x)
    --no-cleanup                Disable automatic terraform destroy on error
    --cleanup-vms               Destroy only VMs (keeps Cloudflare DNS records)
    --cleanup-all               Complete cleanup: VMs + DNS (terraform destroy)

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
    - Cloudflare account with API token (optional, use --skip-cloudflare)
    - .env file with required variables
    - nodes.yaml file with node definitions

EOF
    exit 0
}

# --- Error Handling and Cleanup ---
# This function runs when the script exits with an error
# It performs terraform destroy to clean up partially created infrastructure

CLEANUP_ON_ERROR=true  # Can be set to false with --no-cleanup flag

cleanup_on_error() {
    local exit_code=$?
    [ $exit_code -eq 0 ] || [ "$CLEANUP_ON_ERROR" != true ] && return

    warn "Script failed with exit code $exit_code"
    read -p "Destroy VMs and cleanup? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        info "Skipping cleanup. Run './bootstrap-cluster.sh --cleanup-all' to clean up later."
        return
    fi

    info "Cleaning up infrastructure"
    if [ -n "${VMS_DIR:-}" ] && [ -d "$VMS_DIR" ]; then
        cleanup_vms_only
        success "VMs destroyed"
    else
        warn "Could not locate VMS_DIR for cleanup."
    fi

    if [ -n "${CLUSTER_DIR:-}" ] && [ -d "$CLUSTER_DIR" ]; then
        cd "$CLUSTER_DIR"
        rm -rf ./node-configs 2>/dev/null
        rm -f ./*-patched.yaml ./talosconfig 2>/dev/null
        success "Cluster configs removed (kept: secrets.yaml)"
    fi
}

# Set trap to run cleanup on script exit (only if error occurs)
trap cleanup_on_error EXIT

# --- Initial Setup and Configuration ---

# Determine if we need sudo for privileged operations
# SUDO variable is used throughout the script for commands requiring root
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

# --- Cleanup Functions ---

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
    local nodes_file_path="${NODES_FILE_PATH:-$SCRIPT_DIR/nodes.yaml}"
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

# --- Helper Functions ---

# --- Helper Function: Ensure Custom Talos ISO ---
# Creates a custom Talos ISO with system extensions:
#   - qemu-guest-agent: Better VM integration
#   - amd-ucode: AMD microcode updates
#   - util-linux-tools: Additional utilities
#
# Uses Talos Image Factory API to generate custom ISO with schematic ID

# --- Generic download function with retry and checksum verification ---

download_and_verify() {
    local name="$1"
    local url="$2"
    local dest="$3"
    local checksum_url="$4"
    local pattern="$5"
    local use_sudo="${6:-false}"
    local fatal="${7:-true}"

    local cmd_prefix=""
    if [ "$use_sudo" = "true" ]; then
        cmd_prefix="$SUDO"
    fi

    debug "Checking ${name}..."

    if $cmd_prefix test -f "$dest"; then
        debug "${name} already exists."
        return 0
    fi

    # Download with 3 retries
    info "Downloading ${name}..."
    for i in {1..3}; do
        if $cmd_prefix curl -L --progress-bar -o "$dest" "$url"; then
            debug "Downloaded ${name} successfully."
            $cmd_prefix chmod 644 "$dest"
            break
        fi

        if [ $i -lt 3 ]; then
            warn "Retry $i/3..."
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
    
    debug "Verifying integrity of ${name}..."
    local tmp="/tmp/checksum-$$.txt"

    if ! curl -sL "$checksum_url" > "$tmp"; then
        warn "Checksum download failed for ${name}."
        return 0
    fi

    if [ -n "$pattern" ]; then
        # Extract checksum for specific file pattern
        local expected=$(grep "$pattern" "$tmp" | awk '{print $1}')
        local actual=$($cmd_prefix sha256sum "$dest" | awk '{print $1}')

        if [ "$expected" = "$actual" ]; then
            debug "Verified ${name}."
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
            debug "Verified ${name}."
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


# --- Helper Function: Generate Node-Specific Configuration Patches ---
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

    info "Creating configurations for ${role}s"
    
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
        debug "${name} network patch → ${patch_file}"

        local template_file base_config
        if [ "$role" == "control-node" ]; then
            template_file="$SCRIPT_DIR/templates/control-node-patch.yaml"
            base_config="controlplane.yaml"
        else
            template_file="$SCRIPT_DIR/templates/worker-node-patch.yaml"
            base_config="worker.yaml"
        fi

        # Export variables for yq to use in YAML generation
        # envsubst will replace string placeholders like ${NODE_NAME}.
        export SCHEMATIC_ID="$schematic_id"
        export TALOS_VERSION="$TALOS_VERSION"
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
            .machine.network.nameservers = (env(NAMESERVERS_ARRAY) | .. style="") |
            .cluster.allowSchedulingOnControlPlanes |= (. == "true")' \
          "$template_file" > "$patch_file"
                        
        # Apply patch
        talosctl machineconfig patch "$base_config" --patch @"$patch_file" --output "$name-patched.yaml"
    done < <(yq e ".nodes[] | select(.role == \"${role}\")" "$NODES_FILE_PATH" -o=json -I=0 | jq -c '.')
}

# Define retry function for config application
apply_config_with_retry() {
  local node_name=$1
  local node_ip=$2
  local config_file=$3
  local max_attempts=3
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    # Apply config WITH --mode=reboot so Talos handles the reboot properly
    if talosctl -n "$node_ip" apply-config --insecure --file "$config_file" --mode=reboot; then
      return 0
    fi

    attempt=$((attempt + 1))
    if [ $attempt -le $max_attempts ]; then
      sleep 5
    fi
  done

  return 1
}

# poll_until MSG TIMEOUT INTERVAL CMD...
# Runs CMD every INTERVAL seconds until it succeeds or TIMEOUT expires.
# Prints dots, returns 0 on success or 1 on timeout.
poll_until() {
    local msg="$1"; shift
    local timeout="$1"; shift
    local interval="$1"; shift
    local elapsed=0

    echo -n "$msg"
    while [ "$elapsed" -lt "$timeout" ]; do
        if "$@" &>/dev/null; then
            echo " ✓ (${elapsed}s)"
            return 0
        fi
        echo -n "."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    echo ""
    return 1
}

# --- Helper Functions for Logging ---
info() { echo -e "==> $*"; }
success() { echo -e "✓ $*"; }
warn() { echo -e "⚠ $*" >&2; }
error() { echo -e "✗ Error: $*" >&2; exit 1; }
debug() { [ "${DEBUG:-false}" = true ] && echo -e "  [debug] $*" || true; }

# --- Spinner and Wait Function ---
wait_with_spinner() {
    local msg="$1"; shift; local cmd=("$@")
    
    # Run command in background
    "${cmd[@]}" &> /dev/null &
    local cmd_pid=$!

    # Simple spinner animation
    tput civis
    local spin_chars='/-\|'
    local i=0
    echo -n "$msg "
    
    while kill -0 $cmd_pid 2>/dev/null; do
        printf "%s" "${spin_chars:i++%${#spin_chars}:1}"
        sleep 0.2
        printf "\b"
    done
    
    tput cnorm
    wait $cmd_pid
    local exit_code=$?
    
    if [ "$exit_code" -eq 0 ]; then
        echo "✓"
    else
        echo "✗"
        error "Previous step failed."
    fi
}

# --- Main Logic Functions ---

# Node-lookup helpers (read NODES_FILE_PATH).
get_ips_by_role()   { yq e ".nodes[] | select(.role == \"$1\") | .ip"      "$NODES_FILE_PATH"; }
get_names_by_role() { yq e ".nodes[] | select(.role == \"$1\") | .name"    "$NODES_FILE_PATH"; }
count_by_role()     { yq e "[.nodes[] | select(.role == \"$1\")] | length" "$NODES_FILE_PATH"; }

ensure_cli_tools_installed() {
  info "Checking for required tools (kubectl, yq, openssl)..."
  for cmd in kubectl yq openssl; do
      if ! command -v "$cmd" &> /dev/null; then
          error "'$cmd' is not installed or not in your PATH."
      fi
  done
  success "All required tools are present."
}
ensure_flux_dependencies_ready() {
    info "Reconciling Flux before waiting for HelmReleases..."
    flux reconcile source git flux-system --timeout=5m || true
    flux reconcile kustomization flux-system --with-source --timeout=5m || true

    info "Ensuring OpenBao's Flux dependencies are ready..."
    local dependencies=("cilium" "cert-manager" "longhorn")

    for dep in "${dependencies[@]}"; do
        echo "==> Waiting for $dep HelmRelease to be created..."
        for i in {1..60}; do
            if kubectl get helmrelease "$dep" -n "${HELMRELEASE_NAMESPACE}" &>/dev/null; then
                break
            fi
            if [[ $i -eq 60 ]]; then
                error "HelmRelease '$dep' was not created in ${HELMRELEASE_NAMESPACE} within 5 minutes."
            fi
            sleep 5
        done

        echo "==> Waiting for $dep HelmRelease to be Ready..."
        kubectl wait --for=condition=Ready "helmrelease/$dep" \
            -n "${HELMRELEASE_NAMESPACE}" --timeout=10m

        sleep 5

        # NEW: Wait for actual pods
        echo "==> Waiting for $dep pods..."
        case "$dep" in
            cilium)
                kubectl wait --for=condition=Ready pod -l k8s-app=cilium \
                    -n cilium --timeout=5m
                ;;
            cert-manager)
                kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager \
                    -n cert-manager --timeout=5m
                ;;
            longhorn)
                kubectl wait --for=condition=Ready pod -l app=longhorn-manager \
                    -n longhorn --timeout=5m
                ;;
        esac
        
        echo "✓ $dep ready"
    done
}

get_config_from_helmrelease() {
  info "Looking for HelmRelease '${HELMRELEASE_NAME}' in namespace '${HELMRELEASE_NAMESPACE}'..."
  
  local retries=10
  local wait=5
  for ((i=1; i<=retries; i++)); do
      if kubectl get helmrelease "${HELMRELEASE_NAME}" -n "${HELMRELEASE_NAMESPACE}" &> /dev/null; then
          success "HelmRelease found."
          break
      fi
      if [[ $i -eq $retries ]]; then
          error "HelmRelease '${HELMRELEASE_NAME}' not found after ${retries} attempts."
      fi
      echo "    (Attempt $i/${retries}) Not found yet. Retrying in ${wait} seconds..."
      sleep $wait
  done

  wait_with_spinner "Waiting for Flux to process the HelmRelease spec..." \
      kubectl wait --for=jsonpath='{.status.observedGeneration}' \
      "helmrelease/${HELMRELEASE_NAME}" -n "${HELMRELEASE_NAMESPACE}" --timeout=2m

  info "Reading configuration from HelmRelease spec..."
  local hr_yaml
  hr_yaml=$(kubectl get helmrelease "${HELMRELEASE_NAME}" -n "${HELMRELEASE_NAMESPACE}" -o yaml)

  export NAMESPACE=$(echo "$hr_yaml" | yq e '.spec.targetNamespace' -)
  export SECRET_NAME=$(echo "$hr_yaml" | yq e '.spec.values.server.volumes[0].secret.secretName' -)
  export SECRET_KEY_NAME=$(echo "$hr_yaml" | yq e '.spec.values.server.volumes[0].secret.items[0].key' -)

  if [[ -z "$NAMESPACE" || -z "$SECRET_NAME" || -z "$SECRET_KEY_NAME" ]]; then
      error "Failed to read config. Check .spec.targetNamespace and .spec.values.server.volumes."
  fi
}
create_unseal_secret() {
  # Generates a base64-encoded 32-byte random key and stores it as a K8s secret.
  # This key is used by the OpenBao seal "static" config for auto-unseal.
  # The key is printed to the terminal — back it up in a password manager immediately.
  # Without this key the cluster cannot auto-unseal after a restart.
  #
  # NOTE: double base64 encoding is expected and correct.
  # openssl rand -base64 32 produces a base64 string.
  # --from-literal stores it as-is; Kubernetes then base64-encodes it internally.
  # When reading back: kubectl get secret -o json | jq -r '.data."unseal-key"' | base64 -d
  #   → gives back the original base64 string. That is the correct key value.
  # NOTE: jq key has a hyphen — must be quoted: jq -r '.data."unseal-key"' (not .data.unseal-key)
  info "Generating static unseal key and creating secret 'openbao-unseal-key' in namespace 'openbao'..."

  local static_key
  static_key=$(openssl rand -base64 32)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  UNSEAL KEY (back this up now!): $static_key"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Ensure namespace exists — Flux may not have created it yet if the HelmRelease
  # is still waiting for this secret to exist before it can reconcile.
  kubectl create namespace openbao --dry-run=client -o yaml | kubectl apply -f -

  # Must exist BEFORE OpenBao starts — Flux will reconcile once the secret is present.
  kubectl create secret generic openbao-unseal-key \
      -n openbao \
      --from-literal=unseal-key="${static_key}" \
      --dry-run=client -o yaml | kubectl apply -f -

  success "Secret created. Flux will now reconcile the HelmRelease."
}

initialize_bao() {
  # Waits for the openbao-0 pod to be running, checks if already initialized,
  # and if not runs 'bao operator init' with 1 recovery share.
  # Output (root token + recovery key) is saved to openbao-credentials.txt.
  #
  # Uses the HTTP API to check init status instead of 'bao status' — because
  # 'bao status' exits with code 2 when sealed, which would abort the script
  # under set -eu even though the output is valid.

  wait_with_spinner "Waiting for HelmRelease 'openbao' to become ready..." \
      kubectl wait --for=condition=ready "helmrelease/${HELMRELEASE_NAME}" -n "${HELMRELEASE_NAMESPACE}" --timeout=10m

  wait_with_spinner "Waiting for openbao-0 pod to be Running..." \
      kubectl -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=5m

  info "Checking OpenBao initialization status via HTTP API..."
  # Using wget against the local API avoids the bao status exit-code issue.
  local init_status
  init_status=$(kubectl exec -n openbao openbao-0 -- \
      wget -qO- http://127.0.0.1:8200/v1/sys/init 2>/dev/null \
      | grep -o '"initialized":[^,}]*' | cut -d':' -f2)

  if [[ "$init_status" == "true" ]]; then
      success "OpenBao is already initialized. No action needed."
  else
      info "OpenBao is not initialized. Running 'bao operator init'..."
      local init_output
      init_output=$(kubectl exec -n openbao openbao-0 -- bao operator init \
          -recovery-shares=1 \
          -recovery-threshold=1 2>&1)

      echo -e "\n--- [ OpenBao Initialization Output ] ---\n${init_output}\n-----------------------------------------"
      echo "${init_output}" > "${OUTPUT_FILE}"

      success "Initialization complete. Credentials saved to '${OUTPUT_FILE}'."
      info "IMPORTANT: Back up '${OUTPUT_FILE}' — it contains your root token and recovery key."
  fi
}

credentials_prompt() {
    local need=false
    local required_vars="CLUSTER_NAME VMS_DIR CLUSTER_DIR NODES_FILE_PATH TALOS_ISO_URL UBUNTU_IMAGE_URL"
    [ "${SKIP_CLOUDFLARE:-false}" = false ] && required_vars="$required_vars TF_VAR_cloudflare_api_token"
    for var in $required_vars; do
        [ -z "${!var:-}" ] && need=true && break
    done
    [ "$need" = false ] && return 0

    info "Missing required configuration — please enter values below."
    echo "    (Tip: save these in a .env file to skip this prompt next time)"

    _ask() {
        local var="$1" prompt="$2" default="$3"
        [ -n "${!var:-}" ] && return
        read -rp "  $prompt${default:+ [$default]}: " val
        printf -v "$var" '%s' "${val:-$default}"
    }

    _ask CLUSTER_NAME             "Cluster name"              "talos-cluster"
    _ask VMS_DIR                  "Terraform/VMs directory"   "$SCRIPT_DIR/vms"
    _ask CLUSTER_DIR              "Talos config directory"    "$SCRIPT_DIR/cluster"
    _ask NODES_FILE_PATH          "Path to nodes.yaml"        "$SCRIPT_DIR/nodes.yaml"
    _ask TALOS_ISO_URL            "Talos ISO URL"             ""
    _ask UBUNTU_IMAGE_URL         "Ubuntu cloud image URL"    ""
    [ "${SKIP_CLOUDFLARE:-false}" = false ] && _ask TF_VAR_cloudflare_api_token "Cloudflare API token"  ""
}

# --- Initialization ---

# --- Load Environment Variables ---
# Paths (VMS_DIR, CLUSTER_DIR, NODES_FILE_PATH) are auto-set from SCRIPT_DIR.
# .env provides: CLUSTER_NAME, TALOS_ISO_URL, UBUNTU_IMAGE_URL, TF_VAR_*, etc.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMS_DIR="$SCRIPT_DIR/vms"
CLUSTER_DIR="$SCRIPT_DIR/cluster"
NODES_FILE_PATH="$SCRIPT_DIR/nodes.yaml"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a  # Automatically export all variables
    source "$SCRIPT_DIR/.env"
    set +a  # Disable auto-export
fi

# Always enforce script-relative paths (prevent PWD=$(pwd) bugs in .env)
VMS_DIR="$SCRIPT_DIR/vms"
CLUSTER_DIR="$SCRIPT_DIR/cluster"
NODES_FILE_PATH="$SCRIPT_DIR/nodes.yaml"

# --- Generate nodes.yaml from .env topology variables ---
generate_nodes_yaml() {
    local file="$NODES_FILE_PATH"
    info "Generating nodes.yaml from .env topology"

    cat > "$file" <<YAML
nodes:
  - name: "haproxy"
    ip: "${HAPROXY_IP}"
    gateway: "${GATEWAY}"
    nameservers:
$(IFS=','; for ns in $NAMESERVERS; do echo "      - \"$ns\""; done)
    vcpus: ${HAPROXY_VCPUS:-1}
    memory_mib: ${HAPROXY_MEMORY_MIB:-768}
    disk_size_gib: ${HAPROXY_DISK_GIB:-20}
    role: "haproxy"
YAML

    # Generate control plane nodes
    local base_ip="${CP_BASE_IP}"
    local ip_prefix="${base_ip%.*}"
    local ip_start="${base_ip##*.}"

    for i in $(seq 1 "${CP_COUNT}"); do
        local ip="${ip_prefix}.$((ip_start + i - 1))"
        cat >> "$file" <<YAML

  - name: "control-node-${i}"
    ip: "${ip}"
    gateway: "${GATEWAY}"
    nameservers:
$(IFS=','; for ns in $NAMESERVERS; do echo "      - \"$ns\""; done)
    vcpus: ${CP_VCPUS:-4}
    memory_mib: ${CP_MEMORY_MIB:-8192}
    disk_size_gib: ${CP_DISK_GIB:-50}
    role: "control-node"
YAML
    done

    # Generate worker nodes
    if [ "${WORKER_COUNT:-0}" -gt 0 ]; then
        local w_base_ip="${WORKER_BASE_IP}"
        local w_ip_prefix="${w_base_ip%.*}"
        local w_ip_start="${w_base_ip##*.}"

        for i in $(seq 1 "${WORKER_COUNT}"); do
            local ip="${w_ip_prefix}.$((w_ip_start + i - 1))"
            cat >> "$file" <<YAML

  - name: "worker-node-${i}"
    ip: "${ip}"
    gateway: "${GATEWAY}"
    nameservers:
$(IFS=','; for ns in $NAMESERVERS; do echo "      - \"$ns\""; done)
    vcpus: ${WORKER_VCPUS:-4}
    memory_mib: ${WORKER_MEMORY_MIB:-6144}
    disk_size_gib: ${WORKER_DISK_GIB:-255}
    role: "worker-node"
YAML
        done
    fi

    success "Generated $file (${CP_COUNT} CP + ${WORKER_COUNT:-0} Worker + HAProxy)"
}

# Generate nodes.yaml if topology variables are set
if [ -n "${CP_COUNT:-}" ] && [ -n "${HAPROXY_IP:-}" ]; then
    generate_nodes_yaml
fi

# --- Parse Command-Line Arguments ---

SKIP_TERRAFORM=false
SKIP_ISO_DOWNLOAD=false
SKIP_CONFIG_CREATION=false
SKIP_BOOTSTRAP=false
SKIP_CILIUM_INSTALLATION=false
SKIP_ARGOCD_INSTALLATION=true
SKIP_FLUXCD_INSTALLATION=false
SKIP_INIT_OPENBAO=false
SKIP_CLOUDFLARE=false
DEBUG=false

for arg in "$@"; do
    case $arg in
        -h|--help)
            show_help
            ;;
        --skip-iso-download)
            SKIP_ISO_DOWNLOAD=true
            ;;
        --skip-terraform)
            SKIP_TERRAFORM=true
            ;;
        --skip-config-creation)
            SKIP_CONFIG_CREATION=true
            ;;
        --skip-bootstrap)
            SKIP_BOOTSTRAP=true
            ;;
        --skip-cilium-installation)
            SKIP_CILIUM_INSTALLATION=true
            ;;
        --skip-argocd-installation)
            SKIP_ARGOCD_INSTALLATION=true
            ;;
        --skip-fluxcd-installation)
            SKIP_FLUXCD_INSTALLATION=true
            ;;
        --skip-init-openbao)
            SKIP_INIT_OPENBAO=true
            ;;
        --skip-cloudflare)
            SKIP_CLOUDFLARE=true
            ;;
        --debug)
            DEBUG=true
            ;;
        --no-cleanup)
            CLEANUP_ON_ERROR=false
            echo "Automatic cleanup on error is disabled."
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

# Set defaults for download paths/URLs if not set by .env
METALISO_ABSOLUTE_PATH="${METALISO_ABSOLUTE_PATH:-$VMS_DIR/metal-amd64.iso}"
TALOS_CHECKSUM_URL="${TALOS_CHECKSUM_URL:-https://github.com/siderolabs/talos/releases/latest/download/sha256sum.txt}"
UBUNTU_IMAGE_PATH="${UBUNTU_IMAGE_PATH:-/var/lib/libvirt/images/resolute-server-cloudimg-amd64.img}"
UBUNTU_CHECKSUM_URL="${UBUNTU_CHECKSUM_URL:-}"

# Control plane scheduling — can be overridden in .env
# Auto-detected in main() based on worker node count if not set
export ALLOW_SCHEDULING_ON_CONTROL_PLANES="${ALLOW_SCHEDULING_ON_CONTROL_PLANES:-auto}"

credentials_prompt

# Auto-detect running cluster — set SKIP_* flags if cluster already exists
if [ "$SKIP_BOOTSTRAP" = false ] && [ -f "$CLUSTER_DIR/talosconfig" ] && \
   [ -f "${HOME}/.kube/config" ] && \
   kubectl get nodes --request-timeout=10s &>/dev/null 2>&1; then
    export TALOSCONFIG="$CLUSTER_DIR/talosconfig"
    export KUBECONFIG="${HOME}/.kube/config"
    echo "==> Existing cluster detected — skipping ISO download, VM creation, config generation and bootstrap."
    SKIP_ISO_DOWNLOAD=true
    SKIP_TERRAFORM=true
    SKIP_CONFIG_CREATION=true
    SKIP_BOOTSTRAP=true
    # Check if Cilium is fully running (not just namespace exists)
    if kubectl get pods -n cilium -l app.kubernetes.io/name=cilium-agent -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
        echo "==> Cilium already running — skipping."
        SKIP_CILIUM_INSTALLATION=true
    fi
    # Check if ArgoCD is already installed
    if kubectl get ns argocd &>/dev/null 2>&1; then
        echo "==> ArgoCD already installed — skipping."
        SKIP_ARGOCD_INSTALLATION=true
    fi
    # Check if FluxCD is already installed
    if kubectl get ns flux-system &>/dev/null 2>&1; then
        echo "==> FluxCD already installed — skipping."
        SKIP_FLUXCD_INSTALLATION=true
    fi
fi

if [[ "$DEBUG" == "true" ]]; then
    info "DEBUG mode enabled (set -x + pipefail)"
    set -x
    set -o pipefail
fi

# --- Phases ---


phase_download_images() {
# --- Step 0: Download Required Images (Talos ISO and Ubuntu Cloud Image) ---
# Downloads and verifies:
#   - Talos metal ISO for Kubernetes nodes
#   - Ubuntu cloud image for HAProxy load balancer
# Both downloads include SHA256 checksum verification

if [ "$SKIP_ISO_DOWNLOAD" = false ]; then
    cd "${VMS_DIR}"
    
    info "Downloading images"
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
    debug "Skipping iso-download as requested."
fi
}


phase_create_vms() {
# --- Step 1: Create VMs with Terraform ---
# Uses Terraform to:
#   - Create libvirt VMs for control plane and worker nodes
#   - Create HAProxy load balancer VM
#   - Configure Cloudflare DNS records
#   - Attach Talos ISO to nodes for initial boot

if [ "$SKIP_TERRAFORM" = false ]; then
    BRIDGE_NAME=$(ip -o link show type bridge | awk -F': ' '{print $2}' | head -n 1)
    if [ -z "$BRIDGE_NAME" ]; then
        error "No bridge interface found. Please create one and try again."
    fi

    cd "${VMS_DIR}"

    debug "Found bridge interface: $BRIDGE_NAME"
    export TF_VAR_bridge_name=$BRIDGE_NAME

    info "Applying Terraform configuration"
    terraform init -input=false
    if [ "$SKIP_CLOUDFLARE" = true ]; then
        debug "Skipping Cloudflare DNS records as requested."
        export TF_VAR_enable_cloudflare=false
    fi
    if ! terraform apply; then
        warn "Terraform apply failed — cleaning up created VMs..."
        terraform destroy
        exit 1
    fi

    # Verify VMs were actually created
    EXPECTED_NODES=$(yq e '.nodes[] | .name' "$NODES_FILE_PATH" | wc -l)
    CREATED_VMS=$($SUDO virsh list --all | grep -E "control-node|worker-node|haproxy" | wc -l)

    if [ "$CREATED_VMS" -ne "$EXPECTED_NODES" ]; then
        warn "Expected $EXPECTED_NODES VMs but found $CREATED_VMS. Some VMs may not have been created."
    else
        success "All $CREATED_VMS VMs created."
    fi
fi
}


phase_preflight() {
# --- Step 2: Setup and Pre-flight Checks ---
# Prepare for cluster bootstrapping:
#   - Install required tools (talosctl, yq, jq, arp-scan)
#   - Create cluster directory
#   - Extract configuration from Terraform output

# talosctl configuration

# Create cluster directory if it doesn't exist
if [ ! -d "$CLUSTER_DIR" ]; then
    debug "Cluster directory '$CLUSTER_DIR' does not exist. Creating it."
    mkdir -p "$CLUSTER_DIR"
fi

cd "${CLUSTER_DIR}"

# Check if talosctl is installed, if not, install it
if ! command -v talosctl &> /dev/null; then
    info "Installing talosctl"
    curl -sL https://talos.dev/install | $SUDO sh
fi

info "Step 2a: Performing pre-flight checks"

# Install required command-line tools if not already present
# - yq: YAML processor for reading nodes.yaml
# - jq: JSON processor for parsing Terraform output
# - curl: HTTP client for downloads
# - arp-scan: Network scanner for discovering node IPs
# - genisoimage/mkisofs: Required by terraform-provider-libvirt for cloud-init ISO creation
# - openssl: Used for generating secrets
# - terraform: Infrastructure provisioning
# - helm: Kubernetes package manager (used by Cilium install)
missing_pkgs=()
command -v yq       &>/dev/null || missing_pkgs+=(yq)
command -v jq       &>/dev/null || missing_pkgs+=(jq)
command -v curl     &>/dev/null || missing_pkgs+=(curl)
command -v openssl  &>/dev/null || missing_pkgs+=(openssl)
if ! command -v arp-scan &>/dev/null && ! [ -x /usr/sbin/arp-scan ]; then
    missing_pkgs+=(arp-scan)
fi
if ! command -v mkisofs &>/dev/null && ! command -v genisoimage &>/dev/null; then
    missing_pkgs+=(genisoimage)
fi
if [ ${#missing_pkgs[@]} -gt 0 ]; then
    echo "Installing missing packages: ${missing_pkgs[*]}"
    $SUDO apt-get update && $SUDO apt-get install -y "${missing_pkgs[@]}"
fi
if ! command -v terraform &> /dev/null; then
    echo "terraform not found, installing..."
    $SUDO apt-get update && $SUDO apt-get install -y gnupg lsb-release wget
    wget -O- https://apt.releases.hashicorp.com/gpg | $SUDO gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | $SUDO tee /etc/apt/sources.list.d/hashicorp.list
    $SUDO apt-get update && $SUDO apt-get install -y terraform
fi
if ! command -v helm &> /dev/null; then
    echo "helm not found, installing..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | $SUDO bash
fi
}


phase_generate_configs() {
# --- Step 3: Generate Talos Secrets and Machine Configurations ---
# Generate:
#   - Secrets bundle (certificates, tokens, keys)
#   - Base machine configs for control plane and workers
#   - Configure Kubernetes API endpoint (HAProxy IP)
# Only run if NOT skipping config creation

cd "$CLUSTER_DIR"

if [ "$SKIP_CONFIG_CREATION" = false ]; then
    info "Step 2b: Detecting install disk from VM configuration"

    # Get the actual disk device from a control node VM
    FIRST_CONTROL_NODE=$(get_names_by_role control-node | head -1)
    DISK_TARGET=$($SUDO virsh domblklist "$FIRST_CONTROL_NODE" 2>/dev/null | grep -v "^$" | tail -n +3 | grep -v ".iso" | awk '{print $1}' | head -1)

    if [ -z "$DISK_TARGET" ]; then
        warn "Could not detect disk from VM, using default /dev/vda"
        INSTALL_DISK="/dev/vda"
    else
        # virsh shows the target (e.g., 'vda'), we need full path
        INSTALL_DISK="/dev/${DISK_TARGET}"
        debug "Detected install disk from VM: ${INSTALL_DISK}"
    fi

    info "Step 3a: Generating secrets bundle"
    if [ ! -f "secrets.yaml" ]; then
        talosctl gen secrets --output-file secrets.yaml
    else
        debug "Secrets bundle 'secrets.yaml' already exists."
    fi

    if [ -z "$HAPROXY_IP" ]; then
        error "Could not find HAProxy IP in $NODES_FILE_PATH"
    fi
    debug "Kubernetes endpoint: ${K8S_ENDPOINT}"

    info "Step 3c: Generating machine configurations"

    if [ -f "controlplane.yaml" ]; then
        warn "Machine configurations already exist — regeneration may break access to existing cluster."
        read -p "Do you want to overwrite them? (yes/no): " -r
        echo
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            info "Using existing configs."
        else
            rm -f controlplane.yaml worker.yaml 2>/dev/null
            talosctl gen config "$CLUSTER_NAME" "$K8S_ENDPOINT" --output-dir . --with-secrets ./secrets.yaml --install-disk "$INSTALL_DISK" --force
            success "Generated machine configurations with install disk: $INSTALL_DISK"
        fi
    else
        # First time generation
        talosctl gen config "$CLUSTER_NAME" "$K8S_ENDPOINT" --output-dir . --with-secrets ./secrets.yaml --install-disk "$INSTALL_DISK" --force
        success "Generated machine configurations with install disk: $INSTALL_DISK"
    fi

    # fix         * static hostname is already set in v1alpha1 config
    # Remove HostnameConfig document - hostname is set per-node in patches
    yq -i 'select(.kind != "HostnameConfig")' controlplane.yaml
    [ -f worker.yaml ] && yq -i 'select(.kind != "HostnameConfig")' worker.yaml

    # Remove worker.yaml if no workers configured (talosctl always generates both)
    if [ "${WORKER_NODE_COUNT:-0}" -eq 0 ] && [ -f "worker.yaml" ]; then
        rm -f worker.yaml
        debug "Removed worker.yaml (no worker nodes configured)"
    fi
else
    info "Step 3: Skipping config generation (--skip-config-creation flag set)"
    debug "Using existing configs. Expecting: secrets.yaml, controlplane.yaml, worker.yaml"
    INSTALL_DISK="/dev/vda"  # Default, won't be used for generation
fi

# --- Step 4: Wait for VMs to Boot from ISO ---
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

info "Step 4-5: Generating node-specific configurations"
cd "$CLUSTER_DIR"
mkdir -p ./node-configs

if [ "$SKIP_CONFIG_CREATION" = true ]; then
    debug "Skipping node-specific config generation (--skip-config-creation flag set)."
else
    debug "Found ${CONTROL_NODE_COUNT} control node(s) and ${WORKER_NODE_COUNT} worker node(s)."

    # Use the new helper function to create patch files.
    generate_patch_files_by_role "control-node"
    if [ "$WORKER_NODE_COUNT" -gt 0 ]; then
        generate_patch_files_by_role "worker-node"
    fi
fi
}


phase_bootstrap() {
# --- Steps 6-9: Bootstrap Process ---
# Only run if NOT skipping bootstrap

if [ "$SKIP_BOOTSTRAP" = false ]; then

echo -e "\n==> Continuing with node installation and bootstrap..."

# --- Step 6: Discover Dynamic IPs and Apply Configurations ---
# Workflow:
#   1. Discover nodes via arp-scan (they have DHCP IPs now)
#   2. Match MAC addresses from Terraform to discovered IPs
#   3. Eject ISO from all nodes
#   4. Apply machine configs to dynamic IPs with --mode=reboot
#   5. Nodes reboot and boot from disk with static IPs configured

info "Step 6: Verifying HAProxy at ${HAPROXY_IP}:6443"

if ! poll_until "Waiting for HAProxy on port 6443" 360 10 \
        bash -c "nc -z -w 5 \"$HAPROXY_IP\" 6443 || echo > /dev/tcp/${HAPROXY_IP}/6443"; then
    warn "HAProxy not responding after 6 minutes — continuing anyway (check: ssh lb_user@${HAPROXY_IP})"
fi

echo -e "\n==> Step 7: Applying configurations to nodes..."


cd "$VMS_DIR"

# Ensure BRIDGE_NAME is set (may not be if --skip-terraform was used)
if [ -z "${BRIDGE_NAME:-}" ]; then
    BRIDGE_NAME=$(ip -o link show type bridge | awk -F': ' '{print $2}' | head -n 1)
    if [ -z "$BRIDGE_NAME" ]; then
        error "No bridge interface found for arp-scan. Please create one and try again."
    fi
    debug "Detected bridge interface: $BRIDGE_NAME"
fi

# Discovery parameters
RETRY_COUNT=0
MAX_RETRIES=24  # 24 * 5s = 2 minutes max wait
RETRY_DELAY=5
DYNAMIC_IPS=""
EXPECTED_NODE_COUNT=$(yq e '[.nodes[] | select(.role != "haproxy")] | length' "$NODES_FILE_PATH")

# Discover nodes by matching MAC addresses (from Terraform) to IPs (from arp-scan)
info "Discovering ${EXPECTED_NODE_COUNT} Talos nodes via arp-scan"

while [ -z "$DYNAMIC_IPS" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  # Run the discovery command
  DISCOVERED_IPS=$(join -1 1 -2 1 -o 1.2,2.2 \
      <(terraform output -json | jq -r '.node_macs.value | to_entries[] | "\(.value | ascii_downcase) \(.key)"' | sort -k1,1) \
      <($SUDO arp-scan --interface="$BRIDGE_NAME" --localnet | awk '/:/ {print $2, $1}' | sort -k1,1))

  if [ -n "$DISCOVERED_IPS" ]; then
      # If we have IPs and at least one responds, we're good
      FOUND_COUNT=$(echo "$DISCOVERED_IPS" | wc -l)
      if [ "$FOUND_COUNT" -ge "$EXPECTED_NODE_COUNT" ]; then
          DYNAMIC_IPS="$DISCOVERED_IPS"
          break
      fi
  fi

  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $((RETRY_COUNT % 4)) -eq 0 ]; then
      debug "[${RETRY_COUNT}×${RETRY_DELAY}s] Still waiting for nodes to boot..."
  fi
  sleep $RETRY_DELAY
done

# Fail if no nodes are found after all retries
if [ -z "$DYNAMIC_IPS" ]; then
  warn "Failed to discover any node IPs with arp-scan after $((MAX_RETRIES * RETRY_DELAY))s."
  echo "--- Diagnostics ---"
  echo "VM Status:"
  virsh list --all
  echo "arp-scan raw output:"
  $SUDO arp-scan --interface="$BRIDGE_NAME" --localnet
  echo "-------------------"
  exit 1
fi

FOUND_COUNT=$(echo "$DYNAMIC_IPS" | wc -l)
success "Discovered ${FOUND_COUNT}/${EXPECTED_NODE_COUNT} nodes"
if [ "${DEBUG:-false}" = true ]; then
  echo "$DYNAMIC_IPS" | while read -r name ip; do
    debug "$name → $ip"
  done
fi

# Change back to cluster directory where the patched configs are located
cd "$CLUSTER_DIR"

# Export TALOSCONFIG for all subsequent talosctl commands
export TALOSCONFIG="$CLUSTER_DIR/talosconfig"
debug "Using talosconfig: $TALOSCONFIG"

# Filter control and worker nodes from discovered IPs
CONTROL_IPS=$(echo "$DYNAMIC_IPS" | grep '^control-node' || true)
WORKER_IPS=$(echo "$DYNAMIC_IPS" | grep '^worker-node' || true)

# --- Step 7: Install ALL nodes in parallel (control + workers) ---
# Apply configurations to all nodes simultaneously for faster installation
# Then wait only for first control node to be ready before bootstrapping
# Workers will join the cluster automatically after bootstrap completes

info "Step 7: Installing Talos on all nodes (parallel)"

# Combine all node IPs for parallel installation
if [ -n "$WORKER_IPS" ]; then
    ALL_NODE_IPS=$(printf "%s\n%s" "$CONTROL_IPS" "$WORKER_IPS")
else
    ALL_NODE_IPS="$CONTROL_IPS"
fi

if [ -z "$ALL_NODE_IPS" ]; then
  error "No nodes found in discovered IPs!"
fi

TOTAL_NODES=$(echo "$ALL_NODE_IPS" | wc -l)
info "Phase 7.1: Applying configurations to ${TOTAL_NODES} node(s)"

NODE_NUMBER=1
FAILED_NODES=""

declare -A job_pids
while read -r name dyn_ip; do
  debug "[${NODE_NUMBER}/${TOTAL_NODES}] Applying config to ${name} (${dyn_ip})..."
  (
    if ! apply_config_with_retry "$name" "$dyn_ip" "./${name}-patched.yaml"; then
      exit 1
    fi
  ) &
  job_pids[$!]=$name
  NODE_NUMBER=$((NODE_NUMBER + 1))
done < <(echo "$ALL_NODE_IPS")

# Wait for all background jobs and check exit codes
failed=()
for pid in "${!job_pids[@]}"; do
  if ! wait "$pid"; then
    failed+=("${job_pids[$pid]}")
  fi
done

# Check for failures
if [ ${#failed[@]} -gt 0 ]; then
  FAILED_NODES="${failed[*]}"
  warn "Some nodes failed to apply config: $FAILED_NODES — continuing with remaining nodes..."
else
  success "All configs applied"
fi

# Set persistent boot order to hd,cdrom for every node.
#
# Why this is a one-liner and not a whole phase:
#   apply-config --mode=reboot above causes Talos to install to disk and kexec
#   directly into the installed system. The node is already running from disk
#   on its static IP by the time we get here — no BIOS reboot happened, no
#   ISO re-boot to race with. We just need to update the *persistent* libvirt
#   XML so the next cold power-on (host reboot, manual virsh destroy/start,
#   etc.) also lands on disk instead of falling back into the ISO.
#
#   virt-xml --edit operates on persistent XML only; it's safe on a running
#   VM and takes effect on the next cold boot. No shutdown required.
cd "$VMS_DIR"
while read -r name _; do
  [ -z "$name" ] && continue
  if $SUDO virt-xml "$name" --edit --boot hd,cdrom &>/dev/null; then
    echo "✓ ${name}: persistent boot order set to hd,cdrom"
  else
    echo "⚠ ${name}: failed to update persistent boot order"
  fi
done < <(echo "$ALL_NODE_IPS")
cd "$CLUSTER_DIR"

# (Old Phase 7.2 removed — see commit history. The old wait-for-two-reboots +
#  destroy + start dance was defending against an install failure caused by
#  a missing v-prefix on the factory image tag, fixed in d3415a8. With the
#  install actually succeeding, Talos kexecs into the installed system and
#  Phase 7.2 had nothing to do except flip the persistent boot order — which
#  is now the one line above.)

info "Phase 7.2: Waiting for first control node"
debug "talosctl endpoints: $CONTROL_STATIC_IPS"
talosctl config endpoint $CONTROL_STATIC_IPS

FIRST_READY=""
MAX_WAIT=180 # 3min — extra time after boot order change + VM restart
ELAPSED=0

while [ -z "$FIRST_READY" ] && [ $ELAPSED -lt $MAX_WAIT ]; do
  for ip in $CONTROL_STATIC_IPS; do
    if talosctl -n "$ip" version --client=false &>/dev/null; then
      FIRST_READY="$ip"
      success "First control node ready: $ip (${ELAPSED}s)"
      break
    fi
  done

  if [ -z "$FIRST_READY" ]; then
    if [ $((ELAPSED % 10)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
      debug "  [${ELAPSED}s] still waiting..."
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
  fi
done

if [ -z "$FIRST_READY" ]; then
  error "No control nodes ready after ${MAX_WAIT}s — check node status manually."
fi

# Close the skip-bootstrap conditional that started at Step 2
else
    info "Steps 2-7: Skipped (--skip-bootstrap enabled)"
    cd "${CLUSTER_DIR}"
    talosctl config endpoint $CONTROL_STATIC_IPS
    export TALOSCONFIG="$CLUSTER_DIR/talosconfig"
    debug "Using talosconfig: $TALOSCONFIG"
fi

# At this point, first control node is ready! Bootstrap immediately.

# --- Step 8: Bootstrap Kubernetes Cluster ---
# Initialize the Kubernetes cluster on the first control plane node
# This creates the etcd cluster and starts Kubernetes components

if [ "$SKIP_BOOTSTRAP" = false ]; then
    info "Step 8: Bootstrapping Kubernetes cluster on ${FIRST_READY}"
    poll_until "Waiting to bootstrap" 300 10 talosctl -n "${FIRST_READY}" bootstrap \
        && success "Bootstrap accepted" \
        || warn "Bootstrap returned non-zero — may already be bootstrapped, continuing..."

    if poll_until "Waiting for etcd" 180 10 \
            talosctl -n "$FIRST_READY" service etcd status 2>/dev/null; then
        success "Etcd is running"
    else
        warn "Could not verify etcd status after 180s (may still be starting)"
    fi
else
    info "Step 8: Skipping bootstrap as requested"
    FIRST_CP_STATIC_IP=$(get_ips_by_role control-node | head -1)
fi

# --- Step 8a: Wait for Remaining Control Nodes to Join ---
# Now that bootstrap is complete, wait for other control nodes to join etcd

if [ "$SKIP_BOOTSTRAP" = false ]; then
  if [ "$CONTROL_NODE_COUNT" -gt 1 ]; then
      info "Step 8a: Waiting for ${CONTROL_NODE_COUNT} control nodes to join etcd"
      READY_NODES="$FIRST_READY"
      for ip in $CONTROL_STATIC_IPS; do
          echo "$READY_NODES" | grep -q "$ip" && continue
          if poll_until "  Waiting for control node $ip" 90 2 talosctl -n "$ip" version --client=false; then
              READY_NODES="$READY_NODES $ip"
              debug "Control node joined: $ip [$(echo "$READY_NODES" | wc -w)/${CONTROL_NODE_COUNT}]"
          fi
      done

      FINAL_COUNT=$(echo "$READY_NODES" | wc -w)
      [ "$FINAL_COUNT" -ge "$CONTROL_NODE_COUNT" ] \
          && success "All ${CONTROL_NODE_COUNT} control nodes joined" \
          || warn "Only ${FINAL_COUNT}/${CONTROL_NODE_COUNT} control nodes joined — check: talosctl -n <ip> get members --namespace=os"
  fi

  if [ -n "$WORKER_IPS" ]; then
      info "Step 8b: Verifying worker nodes"
      WORKER_STATIC_IPS=$(get_ips_by_role worker-node | tr '\n' ' ')
      FIRST_WORKER_READY=""
      for ip in $WORKER_STATIC_IPS; do
          if poll_until "Checking worker $ip" 90 2 talosctl -n "$ip" version --client=false; then
              FIRST_WORKER_READY="$ip"
              break
          fi
      done

      [ -n "$FIRST_WORKER_READY" ] \
          && success "Worker nodes are ready and will join the cluster" \
          || warn "No worker nodes ready after 90s — check: kubectl get nodes"
  else
      debug "Step 8b: No worker nodes configured — skipping."
  fi
else
  info "Steps 8a-8b: Skipping node join verification (--skip-bootstrap enabled)"
fi

# --- Step 9: Retrieve Kubeconfig ---
if [ "$SKIP_BOOTSTRAP" = false ]; then
  info "Step 9: Retrieving kubeconfig"
  cd "$SCRIPT_DIR"
  if ! poll_until "Waiting for kubeconfig" 200 10 \
          talosctl -n "$FIRST_READY" kubeconfig --force; then
      warn "Failed to retrieve kubeconfig after 200s — try manually: talosctl -n $FIRST_READY kubeconfig"
  fi
  export KUBECONFIG="${HOME}/.kube/config"
else
  info "Step 9: Skipping kubeconfig retrieval (--skip-bootstrap enabled)"
  export KUBECONFIG="${HOME}/.kube/config"
fi
}


phase_install_cilium() {
# --- Step 10: Install Cilium CNI with KubePrism ---
# Install Cilium using Talos's built-in KubePrism load balancer
# This avoids certificate issues and provides optimal performance

if [ "$SKIP_CILIUM_INSTALLATION" = false ]; then
  info "Step 10: Installing Cilium CNI with KubePrism"

  if ! poll_until "Waiting for Kubernetes API" 600 10 kubectl get nodes; then
      error "Kubernetes API not ready after 10 minutes (check: talosctl -n $FIRST_CP_STATIC_IP service kubelet status)"
  fi

  if ! command -v cilium &> /dev/null; then
      info "Installing Cilium CLI"
      CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
      CLI_ARCH=amd64
      if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
      cd /tmp
      curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
      sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
      $SUDO tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
      rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
      cd "$SCRIPT_DIR"
      debug "Cilium CLI installed"
  fi

  # Cleanup block intentionally preserved — defends against half-installed re-run state.
  # Do not remove without consulting feedback_cilium_cleanup memory.
  debug "Checking for existing Cilium resources..."
  if kubectl get ns cilium &>/dev/null 2>&1; then
      debug "Found existing Cilium, removing..."
      helm uninstall cilium -n cilium --no-hooks 2>/dev/null || true
      timeout 30 cilium uninstall 2>/dev/null || debug "Cilium CLI cleanup completed"
      kubectl delete ns cilium cilium-test --grace-period=0 --force 2>/dev/null || true
      sleep 5
  fi

  # Create cilium namespace with Helm labels/annotations (idempotent)
  kubectl create namespace cilium --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace cilium app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace cilium meta.helm.sh/release-name=cilium meta.helm.sh/release-namespace=cilium --overwrite

  info "Installing Cilium with KubePrism (127.0.0.1:7445)"
  cilium install \
      --version "$CILIUM_VERSION" \
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
  if poll_until "Waiting for Cilium pods" 300 10 \
          bash -c "kubectl get pods -n cilium -l app.kubernetes.io/name=cilium-agent \
                   -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Running"; then
      [ "${DEBUG:-false}" = true ] && cilium status 2>/dev/null || true
      success "Cilium installed"
  else
      warn "Cilium may still be initializing — check: cilium status"
  fi
else
  info "Step 10: Skipping Cilium installation"
fi
}


phase_install_argocd() {
# --- Step 11: Install ArgoCD ---
# Install ArgoCD for GitOps-based application deployment
# Uses HA manifests and installs Gateway API CRDs

if [ "$SKIP_ARGOCD_INSTALLATION" = false ]; then
  info "Step 11: Installing ArgoCD (HA mode)"

  kubectl wait --for=condition=Ready nodes --all --timeout=300s 2>/dev/null || warn "Nodes may still be initializing"

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n argocd apply -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/ha/namespace-install.yaml"
  kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/ha/install.yaml"

  debug "Installing Gateway API CRDs"
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

  kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s || warn "ArgoCD may still be starting"

  ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

  success "ArgoCD installed"
  echo "   • Username: admin"
  if [ -n "$ARGOCD_PASSWORD" ]; then
      echo "   • Password: $ARGOCD_PASSWORD"
  else
      echo "   • Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  fi
  echo "   • Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443"

  if [ -f "$SCRIPT_DIR/argocd/deployment.yml" ]; then
      debug "Found argocd/deployment.yml — apply manually with 'kubectl apply -f argocd/deployment.yml' after creating GitHub secret."
  fi
else
  info "Step 11: Skipping ArgoCD installation"
fi
}


phase_install_fluxcd() {
# --- 12: Install FluxCD ---
if [ "$SKIP_FLUXCD_INSTALLATION" = false ]; then

  info "Step 12: Installing FluxCD"

  kubectl wait --for=condition=Ready nodes --all --timeout=300s \
    || warn "Timed out waiting for all nodes to be Ready — some components may fail."

  if ! command -v kubectl &> /dev/null; then
    info "Installing kubectl"
    curl -Lo /tmp/kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    $SUDO install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm /tmp/kubectl
  fi

  : "${CLOUDFLARE_API_TOKEN:?Error: CLOUDFLARE_API_TOKEN is not set.}"
  : "${GITHUB_REPO_OWNER:?Error: GITHUB_REPO_OWNER is not set.}"
  : "${GITHUB_REPO:?Error: GITHUB_REPO is not set.}"

  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic cloudflare-token -n cert-manager \
    --from-literal=token="$CLOUDFLARE_API_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
    || error "Failed to create/update cloudflare-token secret."

  kubectl create secret generic pihole -n external-dns \
    --from-literal=EXTERNAL_DNS_PIHOLE_PASSWORD="$PIHOLE_PASSWORD" \
    --from-literal=EXTERNAL_DNS_PIHOLE_SERVER="$PIHOLE_SERVER" \
    --from-literal=EXTERNAL_DNS_PIHOLE_API_VERSION="6" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
    || error "Failed to create/update pihole secret."

  # Restart external-dns pods to pick up secret values (if deployment exists)
  echo ""
  if kubectl get deployment -n external-dns --no-headers 2>/dev/null | grep -q .; then
    debug "Restarting external-dns pods to pick up secret values..."
    kubectl rollout restart deployment -n external-dns
    kubectl rollout status deployment -n external-dns --timeout=60s 2>/dev/null || true
  fi

  if ! command -v flux &> /dev/null; then
    info "Installing FluxCD CLI"
    curl -s https://fluxcd.io/install.sh | $SUDO bash
  fi

  info "Running flux bootstrap"
  flux bootstrap github \
    --token-auth \
    --owner="$GITHUB_REPO_OWNER" \
    --repository="$GITHUB_REPO" \
    --branch=main \
    --path=clusters \
    --personal \
    --private=true \
    || error "Flux bootstrap failed (check: kubectl -n flux-system logs -l app=source-controller)"

  # Post-bootstrap verification that GitRepository becomes Ready
  RETRIES=10
  SLEEP_INTERVAL=30
  COUNTER=0
  STATUS=""

  debug "Verifying Flux GitRepository reconciliation"
  while [[ $COUNTER -lt $RETRIES ]]; do
    STATUS=$(kubectl -n flux-system get gitrepositories.source.toolkit.fluxcd.io flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$STATUS" == "True" ]]; then
      break
    fi
    debug "  (Attempt $((COUNTER+1))/$RETRIES) Not ready yet..."
    ((COUNTER++))
    sleep $SLEEP_INTERVAL
  done

  if [[ "$STATUS" != "True" ]]; then
    error "GitRepository failed to become Ready after $RETRIES attempts (check: kubectl -n flux-system logs -l app=source-controller)"
  fi

  success "FluxCD repo ${GITHUB_REPO_OWNER}/${GITHUB_REPO} deployed and reconciled"
else
    info "Step 12: Skipping FluxCD installation"
fi
}


phase_cleanup_temp() {
# --- Cleanup temporary files ---

if [ "$SKIP_BOOTSTRAP" = false ]; then
  debug "Cleaning up node-configs/"
  cd "$CLUSTER_DIR"
  [ -d "./node-configs" ] && rm -rf ./node-configs
fi
}


phase_init_openbao() {
if [ "$SKIP_INIT_OPENBAO" = false ]; then
  HELMRELEASE_NAME="openbao"
  HELMRELEASE_NAMESPACE="flux-system"
  OUTPUT_FILE="openbao-credentials.txt"

  cd "$SCRIPT_DIR"

  info "Starting OpenBao initialization process..."

  ensure_cli_tools_installed
  ensure_flux_dependencies_ready

  create_unseal_secret
  initialize_bao

  success "OpenBao cluster initialized. Will auto-unseal from now on."
else
  info "Skipping OpenBao initialization"
fi
}


print_summary() {
success "Cluster setup complete"
if [ "$SKIP_BOOTSTRAP" = false ]; then
  echo "   • Control nodes: ${CONTROL_NODE_COUNT:-unknown}"
  echo "   • Worker nodes: ${WORKER_NODE_COUNT:-unknown}"
  echo "   • Kubernetes endpoint: ${K8S_ENDPOINT}"
  echo "   • Kubeconfig: $SCRIPT_DIR/kubeconfig"
fi
[ "$SKIP_CILIUM_INSTALLATION" = false ] && echo "   • CNI: Cilium with KubePrism (127.0.0.1:7445)"
[ "$SKIP_ARGOCD_INSTALLATION" = false ] && echo "   • GitOps: ArgoCD (HA mode)"
[ "$SKIP_FLUXCD_INSTALLATION" = false ] && echo "   • GitOps: FluxCD ($GITHUB_REPO_OWNER/$GITHUB_REPO)"
[ "$SKIP_INIT_OPENBAO" = false ] && echo "   • OpenBao: initialized (see openbao-credentials.txt)"
echo "Verify with: kubectl get pods -A"

# --- Disable cleanup trap on successful completion ---
# Script completed successfully, so disable the error cleanup trap

CLEANUP_ON_ERROR=false
}


# --- main ---
main() {
    phase_preflight

    # --- Cluster Topology (read after yq is guaranteed to be installed) ---
    HAPROXY_IP=$(yq e '.nodes[] | select(.name == "haproxy") | .ip' "$NODES_FILE_PATH")
    FIRST_CP_STATIC_IP=$(get_ips_by_role control-node | head -1)
    CONTROL_STATIC_IPS=$(get_ips_by_role control-node | tr '\n' ' ')
    CONTROL_NODE_COUNT=$(count_by_role control-node)
    WORKER_NODE_COUNT=$(count_by_role worker-node)
    K8S_ENDPOINT="https://${HAPROXY_IP}:6443"

    # Auto-detect scheduling on control planes if not explicitly set
    if [ "$ALLOW_SCHEDULING_ON_CONTROL_PLANES" = "auto" ]; then
        if [ "$WORKER_NODE_COUNT" -eq 0 ]; then
            ALLOW_SCHEDULING_ON_CONTROL_PLANES="true"
            echo "==> No worker nodes configured — enabling scheduling on control planes."
        else
            ALLOW_SCHEDULING_ON_CONTROL_PLANES="false"
        fi
        export ALLOW_SCHEDULING_ON_CONTROL_PLANES
    fi

    phase_download_images
    phase_create_vms
    phase_generate_configs
    phase_bootstrap
    phase_install_cilium
    phase_install_argocd
    phase_install_fluxcd
    phase_cleanup_temp
    phase_init_openbao
    print_summary
}

main "$@"

