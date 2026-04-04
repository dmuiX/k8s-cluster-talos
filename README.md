# ☸️ k8s-cluster-talos

Fully automated Talos Linux Kubernetes cluster on KVM/libvirt — one script, zero manual steps.

Terraform provisioning → Cilium CNI → FluxCD GitOps → Cloudflare DNS → Longhorn storage → OpenBao secrets

## 🧱 Stack

| Component               | Version              | Role                                      |
| ----------------------- | -------------------- | ----------------------------------------- |
| Talos Linux             | v1.11.2              | Immutable node OS                         |
| Kubernetes              | v1.34.1              | Orchestration                             |
| KVM/libvirt + Terraform | —                    | VM provisioning                           |
| HAProxy                 | Ubuntu cloud-init    | API load balancer (`<haproxy-ip>:6443`)   |
| Cilium                  | 1.18.2               | CNI, kube-proxy replacement, Gateway API  |
| ArgoCD                  | v3.0.19              | GitOps (optional)                         |
| FluxCD                  | latest               | GitOps (optional)                         |
| OpenBao                 | via FluxCD           | Secrets management (optional)             |
| Cloudflare              | Terraform provider v5| DNS (optional, `--skip-cloudflare`)       |

---

## 🚀 Quick Start

```bash
# 1. Configure
cp .env.example .env && vi .env

# 2. Deploy
./bootstrap-cluster.sh

# 3. Verify
kubectl get nodes
cilium status
```

If `.env` is missing or incomplete, the script prompts for required values interactively.

---

## 🗺️ Topology

Defined entirely in `.env` — the script generates `nodes.yaml` automatically:

```bash
CP_COUNT=3              # Control plane nodes (must be odd for etcd quorum)
CP_MEMORY_MIB=8192      # RAM per CP node
CP_VCPUS=4              # vCPUs per CP node
CP_DISK_GIB=120         # Disk per CP node (qcow2)

WORKER_COUNT=0           # Worker nodes (0 = workloads run on CPs)
# WORKER_MEMORY_MIB=6144 # Only needed if WORKER_COUNT > 0
# WORKER_VCPUS=4
# WORKER_DISK_GIB=255

HAPROXY_IP="192.168.1.20"
CP_BASE_IP="192.168.1.21"    # CPs get .21, .22, .23, ...
WORKER_BASE_IP="192.168.1.31" # Workers get .31, .32, ...
GATEWAY="192.168.1.1"
NAMESERVERS="192.168.1.253,192.168.1.1"
```

When `WORKER_COUNT=0`, the script automatically enables `allowSchedulingOnControlPlanes` so workloads run directly on the control plane nodes. Override with `ALLOW_SCHEDULING_ON_CONTROL_PLANES=true|false` in `.env`.

---

## 💾 Memory Planning

> **QEMU reserves the full assigned RAM per VM on the host**, regardless of actual guest usage.
> The host OOM-killer will terminate QEMU processes when total allocations exceed available host RAM — even if VMs internally show low usage (e.g. 1.5 GiB used out of 8 GiB).

> **Usable host RAM < physical RAM.** GPU VRAM (iGPU/shared), kernel, and BIOS reservations reduce it.
> Example: 32 GiB physical − 4 GiB GPU VRAM = only ~23 GiB usable. Reduce GPU to 512 MiB in BIOS if not actively used → reclaims ~3.5 GiB.

### With 4 GiB GPU VRAM (~27.5 GiB usable)

| Setup                            | VM RAM    | Headroom   | Status                   |
| -------------------------------- | --------- | ---------- | ------------------------ |
| 3 CP (8G) + HAProxy             | 24.8 GiB  | ~2.7 GiB   | works                    |
| 3 CP (5G) + 2 W (5G) + HAProxy  | 25.8 GiB  | ~1.7 GiB   | OOM during FluxCD deploy |
| 3 CP (5G) + 2 W (6G) + HAProxy  | 27.8 GiB  | −0.3 GiB   | OOM                      |
| 3 CP (6G) + 2 W (6G) + HAProxy  | 30.8 GiB  | −3.3 GiB   | OOM                      |

### With 512 MiB GPU VRAM (~30.7 GiB usable)

| Setup                            | VM RAM    | Headroom   | Status      |
| -------------------------------- | --------- | ---------- | ----------- |
| 3 CP (7G) + HAProxy             | 21.8 GiB  | ~8.9 GiB   | safe        |
| **3 CP (8G) + HAProxy**         | 24.8 GiB  | ~5.9 GiB   | recommended |
| 3 CP (9G) + HAProxy             | 27.8 GiB  | ~2.9 GiB   | max config  |
| 3 CP (5G) + 2 W (5G) + HAProxy  | 25.8 GiB  | ~4.9 GiB   | untested    |
| 3 CP (5G) + 2 W (6G) + HAProxy  | 27.8 GiB  | ~2.9 GiB   | untested    |
| 3 CP (6G) + 2 W (6G) + HAProxy  | 30.8 GiB  | −0.1 GiB   | OOM         |

> **Recommendation:** 3 CPs without separate workers on 32 GiB hosts. 5 VMs don't fit reliably.

---

## 🔑 `.env` Variables

```bash
CLUSTER_NAME=k8sdev
BRIDGE_NAME=br0

# --- Cluster Topology (see above) ---
CP_COUNT=3
CP_MEMORY_MIB=8192
CP_VCPUS=4
CP_DISK_GIB=120
WORKER_COUNT=0
HAPROXY_IP="192.168.1.20"
CP_BASE_IP="192.168.1.21"
GATEWAY="192.168.1.1"
NAMESERVERS="192.168.1.253,192.168.1.1"

# Download URLs
# TALOS
TALOS_ISO_URL="https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso"
TALOS_CHECKSUM_URL="https://github.com/siderolabs/talos/releases/latest/download/sha256sum.txt"
TALOS_VERSION="1.12.6"
METALISO_ABSOLUTE_PATH="${VMS_DIR}/metal-amd64.iso"
# Ubuntu
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/resolute/20260328/resolute-server-cloudimg-amd64.img"
UBUNTU_CHECKSUM_URL="https://cloud-images.ubuntu.com/resolute/20260328/SHA256SUMS"
UBUNTU_IMAGE_PATH="/var/lib/libvirt/images/resolute-server-cloudimg-amd64.img"


# Terraform / Cloudflare (optional with --skip-cloudflare)
TF_VAR_cloudflare_api_token=...
TF_VAR_cloudflare_zone_name=...

# FluxCD (optional)
GITHUB_REPO_OWNER=...
GITHUB_REPO=...
GITHUB_TOKEN=...

# External DNS / Pihole (optional)
PIHOLE_PASSWORD=...
PIHOLE_SERVER=...
```

---

## ⚙️ Options

```text
./bootstrap-cluster.sh [OPTIONS]

  --skip-iso-download         Skip ISO downloads (already present)
  --skip-terraform            Skip VM creation (VMs already exist)
  --skip-config-creation      Skip Talos config generation
  --skip-bootstrap            Skip cluster bootstrap (cluster already running)
  --skip-cilium-installation  Skip Cilium
  --skip-argocd-installation  Skip ArgoCD
  --skip-fluxcd-installation  Skip FluxCD
  --skip-init-openbao         Skip OpenBao initialization
  --skip-cloudflare           Skip Cloudflare DNS (no API token needed)

  --debug                     Enable bash -x tracing
  --no-cleanup                Disable automatic cleanup on error
  --cleanup-vms               Destroy VMs only (keep DNS)
  --cleanup-all               Destroy everything (VMs + DNS)
```

---

## 🔄 Bootstrap Flow

```text
bootstrap-cluster.sh
  ├─ credentials_prompt       Ask for missing .env vars interactively
  ├─ phase_preflight          Install tools: talosctl, yq, jq, arp-scan, terraform, helm
  ├─ phase_download_images    Download Talos ISO + Ubuntu cloud image (SHA256 verified)
  ├─ phase_create_vms         terraform apply → KVM VMs + Cloudflare DNS
  ├─ phase_generate_configs   talosctl gen config + node-specific patches
  ├─ phase_bootstrap
  │   ├─ Wait for HAProxy on :6443
  │   ├─ arp-scan → discover DHCP IPs → match to MACs
  │   ├─ Apply configs (talosctl apply-config --mode=reboot)
  │   ├─ Set boot order: disk first, ISO fallback
  │   ├─ Wait for first CP → talosctl bootstrap (etcd init)
  │   ├─ Wait for remaining CPs + workers to join
  │   └─ Retrieve kubeconfig
  ├─ phase_install_cilium     Cilium CNI (KubePrism, Gateway API)
  ├─ phase_install_argocd     ArgoCD HA mode (optional)
  ├─ phase_install_fluxcd     flux bootstrap github (optional)
  ├─ phase_cleanup_temp       Remove temporary node-config files
  ├─ phase_init_openbao       Initialize OpenBao with auto-unseal (optional)
  └─ print_summary
```

The script auto-detects an existing cluster and skips phases that are already done.

---

## ⬆️ Upgrade Talos

```bash
# 1. Generate schematic ID with required extensions
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

# 2. Upgrade all nodes
export TALOSCONFIG=./cluster/talosconfig
talosctl -n <cp-1>,<cp-2>,<cp-3> \
  upgrade --image factory.talos.dev/installer/<schematic-id>:v1.11.2 \
  --preserve --wait=false
```

---

## 📁 File Structure

```text
bootstrap-cluster.sh          Main orchestration script
.env                          Credentials + topology (gitignored)
nodes.yaml                    Auto-generated from .env (gitignored)
templates/                    Talos machine config patches (control + worker)
vms/                          Terraform: KVM domains, HAProxy, Cloudflare DNS
  ├─ optimizations.xsl        VM tuning: IOThreads, CPU, on_crash: restart
  └─ optimizations_haproxy.xsl  HAProxy-specific VM tuning
cluster/                      Generated Talos configs (gitignored)
argocd/                       ArgoCD Application manifest
fluxcd/                       FluxCD bootstrap config
scripts/                      Helper scripts (boot order, YAML validation)
docs/                         Component docs (Cilium, Longhorn, ArgoCD, ...)
```

---

## 🧹 Cleanup

```bash
# Remove VMs only (keep Cloudflare DNS)
./bootstrap-cluster.sh --cleanup-vms

# Remove everything (VMs + DNS records)
./bootstrap-cluster.sh --cleanup-all
```

---

## 📦 ArgoCD Deployment Order

When deploying via ArgoCD, install in this order:

1. Kubernetes (base cluster)
2. Cilium
3. external-dns
4. cert-manager
5. ArgoCD
6. external-secrets
7. gateway-api
8. argocd-apps

---

## 🐛 Troubleshooting

Most cluster issues fall into a few categories:

1. **pods not scheduling** (resources / taints / affinity)
2. **pods crashing** (config / deps / OOM)
3. **traffic not arriving** (routes / services / DNS)
4. **host running out of memory**. Below are typical things that go wrong.

### Pod stuck in `Pending`

Not enough resources, or node affinity / taint mismatch.

```bash
kubectl describe pod -n <ns> <pod-name> | tail -20
```

Common on CP-only clusters: HelmCharts set `nodeAffinity` with `node-role.kubernetes.io/control-plane: DoesNotExist` — override in the HelmRelease values.

### Pod in `CrashLoopBackOff`

Container starts, crashes, Kubernetes retries with increasing backoff (10s → 20s → 40s → ...).

```bash
kubectl logs <pod-name> --previous    # logs from the last crash
kubectl describe pod <pod-name>       # check for OOMKilled in "Last State"
```

Common causes:

1. missing env vars or config
2. OOM kill
3. dependency not ready
4. wrong entrypoint/args
5. permission errors.

### Host OOM kills QEMU VMs

VMs shut off randomly even though guest memory usage is low. QEMU reserves the full assigned RAM regardless of guest usage.

```bash
dmesg | grep -i oom                   # confirm OOM kill
```

Enable **KSM** (Kernel Same-page Merging) to deduplicate identical memory pages across VMs — especially effective with multiple Talos nodes running the same kernel:

```bash
echo 1 | sudo tee /sys/kernel/mm/ksm/run                                        # activate
cat /sys/kernel/mm/ksm/pages_sharing                                             # check effect
echo "w /sys/kernel/mm/ksm/run - - - - 1" | sudo tee /etc/tmpfiles.d/ksm.conf   # persist
```

### GPU VRAM reduces usable host RAM

iGPU / shared memory GPUs allocate VRAM from system RAM. 32 GiB physical with 4 GiB GPU = only ~23 GiB usable. Reduce to 512 MiB in BIOS if the GPU is not actively used → reclaims ~3.5 GiB.

### Pod can't reach the internet

DNS or firewall issue between pod and external network.

```bash
kubectl exec -it <pod> -- wget -qO- https://example.com
kubectl logs -n cilium -l app.kubernetes.io/name=cilium-agent | grep -i drop
```

Check: Cilium NetworkPolicies, CoreDNS running (`kubectl get pods -n kube-system`), host firewall not blocking bridge traffic (`sysctl net.bridge.bridge-nf-call-iptables`).

### Secrets not working

Typos, wrong encoding, or wrong namespace.

```bash
kubectl get secret <name> -n <ns> -o jsonpath='{.data}' | jq 'to_entries[] | .value |= @base64d'
```

Common mistakes: value not Base64-encoded, secret in wrong namespace, key name mismatch between secret and pod spec, extra newline (`echo -n` vs `echo`).

### Traffic not reaching pods

Misconfigured route, ingress, gateway, or service.

Check the full path: **DNS → LoadBalancer/NodePort → Gateway/Ingress → Service → Pod**. Common causes: typo in hostname or path, wrong service name or port, missing HTTPRoute, wrong `targetPort` or `selector` in Service, TLS termination misconfigured.

### HelmRelease not reconciling

Typos in values or dependency not ready.

```bash
kubectl get helmreleases -A
kubectl describe helmrelease <name> -n <ns> | tail -20
```

Check `spec.valuesFrom` references, chart version compatibility, and whether dependent HelmReleases are ready.

---

## ⚠️ Known Issues

| Issue | Details |
| ----- | ------- |
| **Do not set `VMS_DIR` / `CLUSTER_DIR` / `NODES_FILE_PATH` in `.env`** | The script derives paths from `BASH_SOURCE[0]`. Setting these via `PWD=$(pwd)` caused them to resolve to `/` in subshells → configs in wrong directory → TLS cert mismatches. |
| **Pin the Ubuntu image URL** | Don't use `current` — it pulls latest daily builds that can break (e.g. `gateway4` removed in netplan, stricter cloud-init schema). Use a specific dated build. |
| **Terraform Cloud: Local Execution only** | The libvirt provider requires local execution. Remote execution fails with `dial unix /var/run/libvirt/libvirt-sock: no such file or directory`. |
| **cloud-init must be single-line** | Multi-line cloud-init user data breaks with the libvirt Terraform provider. |
| **`prevent_destroy` can't use variables** | `prevent_destroy = var.x` doesn't work in Terraform. Remove the block manually to toggle. |
| **No Talos kernel params via libvirt** | Passing `kernel`/`cmdline` via the Terraform provider causes kernel panic on boot. |
| **VM tuning via XSL, not Terraform** | IOThreads, CPU topology, crash behavior → edit `vms/optimizations.xsl`, not the `.tf` files. Referenced via `xml { xslt = ... }` in `nodes.tf`. |

---

> Built with [Claude Code](https://claude.ai/claude-code)

Tested on Functionality: Works ;)
