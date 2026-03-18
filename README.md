# k8s-cluster-talos

Automated Talos Linux Kubernetes cluster on KVM/libvirt.
One script provisions VMs, installs Talos, bootstraps Kubernetes and sets up the full stack.

## Stack

| Component | Version | Role |
|-----------|---------|------|
| Talos Linux | v1.11.2 | Node OS |
| Kubernetes | v1.34.1 | Orchestration |
| KVM/libvirt + Terraform | — | VM provisioning |
| HAProxy | Ubuntu cloud-init | Load balancer (API endpoint) |
| Cilium | 1.18.2 | CNI, kube-proxy replacement, Gateway API |
| ArgoCD | v3.0.19 | GitOps (optional) |
| FluxCD | latest | GitOps (optional) |
| OpenBao | via FluxCD | Secrets management (optional) |
| Cloudflare | Terraform provider v5 | DNS |

## Topology

Defined in `nodes.yaml` (gitignored — copy from `nodes.yaml.example`):

| Node | Role | vCPUs | RAM |
|------|------|-------|-----|
| haproxy | Load balancer | 1 | 768 MiB |
| control-node-{1,2,3} | Control plane | 4 | 6 GiB |
| worker-node-{1,2} | Worker | 4 | 6 GiB |

Kubernetes API endpoint: `https://<haproxy-ip>:6443`

## Prerequisites

- KVM/libvirt installed and running
- Bridge interface configured (e.g. `br0`)
- Terraform Cloud account (or local backend) for state
- Cloudflare account with API token
- Tools: `yq`, `jq`, `arp-scan`, `talosctl`, `kubectl`
- `.env` and `nodes.yaml` filled in (see examples below)

## Quick Start

```bash
# 1. Fill in credentials and topology
cp .env.example .env && vi .env
cp nodes.yaml.example nodes.yaml && vi nodes.yaml

# 2. Run the bootstrap (full setup)
./bootstrap-cluster.sh

# 3. Verify
kubectl get nodes
cilium status
```

If `.env` is missing or incomplete, the script will prompt for the required values interactively.

## `.env` Variables

```bash
CLUSTER_NAME=talos-cluster
VMS_DIR=./vms
CLUSTER_DIR=./cluster
NODES_FILE_PATH=./nodes.yaml

TALOS_ISO_URL=https://...
TALOS_CHECKSUM_URL=https://...
UBUNTU_IMAGE_URL=https://...
UBUNTU_CHECKSUM_URL=https://...
METALISO_ABSOLUTE_PATH=./vms/metal-amd64.iso
UBUNTU_IMAGE_PATH=./vms/ubuntu.img

# Terraform / Cloudflare
TF_VAR_cloudflare_api_token=...
TF_VAR_cloudflare_zone_id=...
TF_CLOUD_ORGANIZATION=...

# FluxCD (optional)
GITHUB_REPO_OWNER=...
GITHUB_REPO=...
GITHUB_TOKEN=...

# External DNS / Pihole (optional)
PIHOLE_PASSWORD=...
PIHOLE_SERVER=...
CLOUDFLARE_API_TOKEN=...
```

## Options

```
./bootstrap-cluster.sh [OPTIONS]

  --skip-iso-download         Skip ISO downloads (already present)
  --skip-terraform            Skip VM creation (VMs already exist)
  --skip-config-creation      Skip Talos config generation
  --skip-bootstrap            Skip cluster bootstrap (cluster already running)
  --skip-cilium-installation  Skip Cilium
  --skip-argocd-installation  Skip ArgoCD
  --skip-fluxcd-installation  Skip FluxCD
  --skip-init-openbao         Skip OpenBao initialization

  --debug                     Enable bash -x tracing
  --no-cleanup                Disable automatic cleanup on error
  --cleanup-vms               Destroy VMs only (keep DNS)
  --cleanup-all               Destroy everything (VMs + DNS)
```

## Bootstrap Flow

```
bootstrap-cluster.sh
  ├─ credentials_prompt       Ask for missing .env vars interactively
  ├─ phase_download_images    Download Talos ISO + Ubuntu cloud image (SHA256 verified)
  ├─ phase_create_vms         terraform apply → KVM VMs + Cloudflare DNS
  ├─ phase_preflight          Install talosctl, yq, jq, arp-scan if missing
  ├─ phase_generate_configs   talosctl gen-config + node-specific patches via Talos Image Factory
  ├─ phase_bootstrap
  │   ├─ Wait for HAProxy on :6443
  │   ├─ arp-scan → discover DHCP IPs → match to MACs from Terraform
  │   ├─ Apply configs to all nodes in parallel (talosctl apply-config --mode=reboot)
  │   ├─ Set boot order: disk first, ISO as fallback
  │   ├─ Wait for first control node → talosctl bootstrap (etcd init)
  │   ├─ Wait for remaining control nodes to join
  │   ├─ Wait for worker nodes
  │   └─ Retrieve kubeconfig
  ├─ phase_install_cilium     cilium install (KubePrism 127.0.0.1:7445, Gateway API)
  ├─ phase_install_argocd     ArgoCD HA mode + Gateway API CRDs (optional)
  ├─ phase_install_fluxcd     flux bootstrap github (optional)
  ├─ phase_cleanup_temp       Remove temporary node-config files
  ├─ phase_init_openbao       Initialize OpenBao with auto-unseal (optional)
  └─ print_summary
```

## Upgrade Talos

```bash
# Generate schematic ID with required extensions
curl -sX POST "https://factory.talos.dev/schematics" \
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

# Upgrade all nodes
export TALOSCONFIG=./cluster/talosconfig
talosctl -n <control-1>,<control-2>,<control-3>,<worker-1>,<worker-2> \
  upgrade --image factory.talos.dev/installer/<schematic-id>:v1.11.2 \
  --preserve --wait=false
```

## File Structure

```
bootstrap-cluster.sh      Main orchestration script
nodes.yaml                Cluster topology (gitignored — copy from nodes.yaml.example)
nodes.yaml.example        Example topology
templates/                Talos machine config patches (control + worker)
vms/                      Terraform: KVM domains, HAProxy, Cloudflare DNS
cluster/                  Generated Talos configs (gitignored)
argocd/                   ArgoCD Application manifest
fluxcd/                   FluxCD bootstrap config
scripts/                  Helper scripts (boot order, YAML validation)
docs/                     Component docs (Cilium, Longhorn, ArgoCD, ...)
.env                      Credentials (gitignored, never commit)
```

## Cleanup

```bash
# Remove VMs only (keep Cloudflare DNS)
./bootstrap-cluster.sh --cleanup-vms

# Remove everything (VMs + DNS records)
./bootstrap-cluster.sh --cleanup-all
```

## ArgoCD App Deployment Order

When deploying via ArgoCD, install in this order:

1. Kubernetes (base cluster)
2. Cilium
3. external-dns
4. cert-manager
5. ArgoCD
6. external-secrets
7. gateway-api
8. argocd-apps

## Notes / Known Issues

**Terraform Cloud — Local Execution required**
The libvirt provider doesn't work with Remote execution. Set the workspace to _Local Execution_ in Terraform Cloud settings, otherwise you'll get:
```
Error: failed to connect: dial unix /var/run/libvirt/libvirt-sock: connect: no such file or directory
```

**cloud-init config must be a single line**
Multi-line cloud-init user data breaks with the libvirt Terraform provider — keep it inline.

**`prevent_destroy` lifecycle block**
Setting `prevent_destroy = var.some_bool` doesn't work in Terraform. To toggle it, remove the block from the `.tf` file directly and re-apply.

**Talos kernel parameters cause kernel panic**
Don't pass `kernel`/`cmdline` parameters via the libvirt Terraform provider — results in kernel panic on boot.
