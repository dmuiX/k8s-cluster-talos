# ☸️ k8s-cluster-talos

Talos Linux Kubernetes provisioning on KVM/libvirt, orchestrated with Bash and Terraform: from VM creation and machine configuration to Cilium networking and a GitOps handoff.

This repository and **[dmuiX/fluxcd.k8sdev.cloud](https://github.com/dmuiX/fluxcd.k8sdev.cloud)** were the two parts of the same former training cluster, now retained as references:

- **Here — provisioning and bootstrap:** scripts for VM creation, Talos installation, Kubernetes initialization, and initial networking.
- **Companion repository — historical GitOps configuration:** manifests for the former cluster's services and workloads, including the Longhorn and OpenBao dependencies expected by this script.

> **Status: inactive training project, not a production deployment.** This Talos cluster and its companion Flux configuration are no longer active in my infrastructure; my **k3s cluster has replaced this setup**. Both repositories are kept **for reference only**, not as a currently running platform or a freshly validated deployment guide. The tracked code contains environment-specific assumptions and unfinished paths. Review [configuration](#-configuration-reference), [safety notes](#-safety-and-cleanup), and [current limitations](#-current-limitations) before using it on an isolated lab host.

[Architecture](#-architecture-and-bootstrap-flow) · [Prerequisites](#-prerequisites) · [Preparation](#-preparation) · [Troubleshooting](#-troubleshooting) · [Reference notes](#-reference-notes)

## 🤔 Why Talos? Why a single bash script?

This cluster is the result of multiple failed attempts at on-prem Kubernetes:

1. **Multipass + MicroK8s** (Ubuntu) — VMs were unreliable, DNS and hostname handling was a pain
2. **Vagrant** — overly complex, dual IPs and hostname management made it frustrating
3. **Ansible + KVM** — way too much manual plumbing to get right
4. **Oracle Cloud free tier** — free VMs were never actually available

**Why Talos?**
Talos is an immutable, API-driven OS built specifically for Kubernetes — without SSH or a general-purpose package manager. It manages components such as etcd, kubelet, and containerd, removing much of the node configuration needed with general-purpose Linux. Configuration and upgrades use `talosctl`; compatibility, backups, and post-upgrade checks still matter.

**Why one bash script instead of Ansible?**
For this learning project, a single script keeps the sequence of `talosctl`, `terraform`, and Kubernetes CLI operations visible in one place. Named phase functions and retry helpers make the bootstrap process easier to trace. Some existing resources are detected and skipped, but that is not a guarantee of safe, idempotent reruns. Debug tracing can also expose credentials.

## 📦 Stack

| Component | Responsibility |
| --- | --- |
| KVM/libvirt + Terraform | qcow2 disks, bridged Talos VMs, deterministic MAC addresses |
| Talos Linux + Kubernetes | Node OS, control plane, and API virtual IP (`VIRTUAL_IP:6443`) |
| Cilium | CNI, kube-proxy replacement, L2 announcements, and Gateway API support; uses KubePrism on port `7445` |
| FluxCD | Default GitOps handoff to the companion repository |
| ArgoCD | Retained alternative installation function and Application example; see [GitOps choices](#-gitops-choices) |
| Cloudflare | Optional Terraform-managed node DNS records; separate in-cluster DNS/certificate credentials for Flux |
| Longhorn + OpenBao | GitOps-managed storage and secrets services; optional OpenBao initialization here |

There is no single version table: Talos/Cilium inputs come from local configuration, some manifests use fixed versions or `latest`, and other services come from GitOps. Check [provider constraints](vms/provider.tf), [machine patches](templates/), and [script inputs](bootstrap-cluster.sh) together before choosing compatible releases.

## 📋 Prerequisites

- **An x86-64 Linux KVM host** with libvirt running, permission to use `virsh`, and a usable `default` storage pool. The preflight installer assumes an apt-based host and root or `sudo` access; this is not a portable macOS/Windows launcher.
- **A LAN bridge with DHCP** for Talos maintenance-mode discovery, plus unused static node addresses and a control-plane virtual IP on the same network. The VM phase selects the first bridge returned by `ip`; verify that selection on hosts with multiple bridges.
- **Enough RAM and disk space** for all VMs, Talos extensions, and workloads; see [memory planning](#-memory-planning).
- **Working CLI tools:** `kubectl`, Mike Farah `yq` v4, `jq`, `curl`, `openssl`, `arp-scan`, `talosctl`, `terraform`, `helm`, `virsh`, and GNU utilities such as `sha256sum`, `md5sum`, `join`, and `timeout`. Flux/Cilium CLIs are needed for their respective phases. The script attempts to install some missing tools, but uses `kubectl` before its late fallback installer; do not rely on a clean-host dependency setup.
- **Network access** to image releases, Talos Image Factory, package repositories, GitHub, and container registries. Bootstrap downloads tools/manifests; it is not an offline workflow.
- **Credentials for the paths you use:** Cloudflare for node DNS; GitHub and application credentials for the default Flux path. See [configuration](#-configuration-reference) and [GitOps choices](#-gitops-choices).

Review host-specific assumptions in [vms/nodes.tf](vms/nodes.tf) and both [Talos patches](templates/) as well: fixed CPU topology/`topoext`, AMD microcode in the generated schematic, `/24` node addresses, time servers, and reserved hugepages are not universal defaults.

## 🚀 Preparation

1. Read [bootstrap-cluster.sh](bootstrap-cluster.sh), the [Terraform inputs](vms/variables.tf), and the [safety notes](#-safety-and-cleanup). This is a reference implementation, not a copy-and-run deployment contract.
2. Create a private, shell-syntax **`.env`** at the repository root using the [configuration reference](#-configuration-reference). There is **no tracked `.env.example`**. The script sources `.env` as Bash, so only use trusted contents. Its interactive prompt covers a subset of the required inputs, not a complete configuration wizard.
3. Choose a control-plane/worker layout and compatible image/component versions. Keep the downloaded ISO path and Terraform's ISO input aligned; do not use the historical `haproxy` entry in `nodes.yaml.example` for the current flow.
4. Choose whether to use Flux and OpenBao. Both phases are enabled by default. Skipping Flux without also skipping OpenBao leaves initialization waiting for Flux-managed resources.
5. Back up existing libvirt/Terraform state, cluster credentials, and any persistent data before running against an existing environment.

For a **reviewed, disposable lab** with configuration already supplied, this example omits Cloudflare records, Flux, and OpenBao:

```bash
./bootstrap-cluster.sh --skip-cloudflare --skip-fluxcd-installation --skip-init-openbao --no-cleanup
```

This still creates VMs and changes the cluster. **`--no-cleanup` is not a universal destruction guard:** the Terraform failure branch still calls `terraform destroy`. Terraform may also request Cloudflare inputs even with DNS disabled; see [current limitations](#-current-limitations).

After deployment, check the intended kubeconfig context before inspecting resources:

```bash
kubectl config current-context
kubectl get nodes -o wide
kubectl get pods -A
cilium status --namespace cilium
```

## 🌐 Topology

The script regenerates **`nodes.yaml`** from `.env` topology inputs before its main phases, including on detected-cluster reruns. Treat that file as generated output, not the durable place to edit topology. [nodes.yaml.example](nodes.yaml.example) illustrates an older layout and still includes HAProxy; it is not an exact template for current bootstrap.

- `CP_COUNT`, `CP_BASE_IP`, `CP_MEMORY_MIB`, `CP_VCPUS`, `CP_DISK_GIB`: control-plane count, first IP, and resources. An odd control-plane count is the usual etcd quorum layout.
- `WORKER_COUNT`, `WORKER_BASE_IP`, `WORKER_MEMORY_MIB`, `WORKER_VCPUS`, `WORKER_DISK_GIB`: optional workers. Worker base IP is needed when the count is greater than zero.
- `VIRTUAL_IP`, `GATEWAY`, `NAMESERVERS`: control-plane VIP, default gateway, and comma-separated DNS servers. IP generation increments the last IPv4 octet; patches currently use `/24` addresses.

With `WORKER_COUNT=0`, the script enables `allowSchedulingOnControlPlanes`. Override with `ALLOW_SCHEDULING_ON_CONTROL_PLANES=true|false` in `.env`. Actual schedulability also depends on workload taints, affinity, and resources.

---

## 🧠 Memory planning

Budget for **the sum of configured guest RAM plus host/QEMU overhead**, rather than assuming low pod usage makes overcommit safe. QEMU's resident memory depends on guest activity and allocation settings; it is not universally equal to the configured maximum.

For example, three control planes at `8192` MiB each configure **24 GiB of guest RAM**, before host services and VM overhead. That is a planning example, not a tested capacity guarantee. Separate workers add their full memory budgets; a control-plane-only lab can avoid that overhead.

Check actual host-available memory, iGPU/shared-memory reservations, and workload peaks. The Talos patches also reserve hugepages, reducing guest memory available to ordinary workloads. Host OOM kills can terminate VMs even when individual pods appear healthy.

---

## 🔧 Configuration reference

`.env` values are exported when sourced. Use quoted shell assignments and keep credentials private. This table describes inputs, not a ready-to-run configuration.

| Inputs | Purpose / caveat |
| --- | --- |
| `CLUSTER_NAME` | Name passed to `talosctl gen config` |
| Topology variables [above](#-topology) | Counts, resources, addresses, DNS, and optional scheduling override |
| `TALOS_VERSION` | Installer version **without** the leading `v`; both patches add it to the factory image tag |
| `TALOS_ISO_URL`, `TALOS_CHECKSUM_URL` | Select matching release-specific ISO and checksum URLs; the checksum fallback points to `latest`, not necessarily the chosen ISO |
| `METALISO_ABSOLUTE_PATH` | Download destination; defaults to the repository's `vms/metal-amd64.iso` |
| `CILIUM_VERSION` | Version passed to `cilium install`; no script default |
| `TF_VAR_libvirt_uri` | Explicit libvirt connection URI, typically `qemu:///system`; the variable has no declared default |
| `TF_VAR_metaliso_absolute_path` | Absolute ISO path used by Terraform; must match the downloaded file and be readable by libvirt. Not automatically exported from `METALISO_ABSOLUTE_PATH` |
| `TF_VAR_github_owner` | Currently declared as a required Terraform input, although unused in VM resources |
| `TF_VAR_cloudflare_api_token`, `TF_VAR_cloudflare_zone_name` | Node DNS configuration; see the skip-path limitation below |
| `GITHUB_REPO_OWNER`, `GITHUB_REPO`, `GITHUB_TOKEN` | Default Flux bootstrap: intended GitHub owner/repository and token with permission to write bootstrap manifests |
| `CLOUDFLARE_API_TOKEN`, `GRAFANA_USER`, `GRAFANA_PASSWORD` | Required by the Flux phase to create the companion stack's initial Kubernetes Secrets; distinct from Terraform's Cloudflare input |
| `OPENBAO_UNSEAL_KEY` | Set to an existing static unseal key, or explicitly to an empty string for first-time generation. The helper reads it under `set -u` |
| `ARGOCD_VERSION`, `GATEWAY_API_VERSION` | Used by the retained ArgoCD function, if invoked; not defaults for all cluster manifests |

The script derives `VMS_DIR`, `CLUSTER_DIR`, and `NODES_FILE_PATH` from its own location; do not override them in `.env`. It exports `TF_VAR_nodes_file_path` and `TF_VAR_bridge_name` during VM creation. The latter comes from bridge auto-detection, which overwrites a configured `BRIDGE_NAME` in that phase.

Treat `.env`, `cluster/`, generated machine configs, kubeconfigs, Terraform state, and `openbao-credentials.txt` as sensitive. Keep keys and recovery material backed up outside the cluster and out of terminal/session recordings. See [current limitations](#-current-limitations) for version and rerun caveats.

---

## 🧰 Options

```text
./bootstrap-cluster.sh [OPTIONS]

  --help                      Show the script's help text
  --skip-iso-download         Skip the Talos ISO download
  --skip-terraform            Skip VM creation (VMs already exist)
  --skip-config-creation      Skip Talos config generation
  --skip-bootstrap            Skip cluster bootstrap (cluster already running)
  --skip-cilium-installation  Skip Cilium
  --skip-argocd-installation  Skip ArgoCD (already the default)
  --skip-fluxcd-installation  Skip FluxCD (enabled by default)
  --skip-init-openbao         Skip OpenBao initialization (enabled by default)
  --skip-cloudflare           Disable Terraform-managed Cloudflare node DNS records

  --debug                     Enable bash tracing + pipefail; may expose credentials
  --no-cleanup                Disable the exit-trap cleanup, not every destroy path
  --cleanup-vms               Delete generated-topology VMs and their storage; keep DNS
  --cleanup-all               Terraform destroy + deletion of local Talos configs/secrets
```

---

## 🧭 Architecture and bootstrap flow

```text
.env → generated nodes.yaml → Terraform → Talos VMs on a LAN bridge
                                             │
                     DHCP discovery + MAC matching → per-node static config
                                             │
                    Kubernetes bootstrap → API at VIRTUAL_IP:6443
                                             │
                      Cilium → Flux bootstrap → companion GitOps repository
                                                   │
                                      cluster services and workloads
```

The phase functions in [bootstrap-cluster.sh](bootstrap-cluster.sh) make the sequence explicit:

```text
credentials_prompt           Prompt for a subset of missing inputs
phase_preflight              Check/install some CLI dependencies
phase_download_images        Download the Talos ISO; attempt checksum verification
phase_create_vms              Terraform init/apply: disks, VMs, optional node DNS
phase_generate_configs       Generate/reuse secrets; patch configs per node
phase_bootstrap              Discover DHCP IPs; apply configs in parallel; eject CP ISOs
                             Wait for a control plane; bootstrap etcd; fetch kubeconfig
phase_install_cilium         Install networking with KubePrism on localhost:7445
phase_install_argocd         Retained HA installation path; skipped by default
phase_install_fluxcd         Create initial Secrets; flux bootstrap github
phase_cleanup_temp           Remove temporary node-config patches
phase_init_openbao           Wait for Flux dependencies; create unseal Secret; initialize
print_summary                Print a summary (verify actual health separately)
```

The machine patches disable the default CNI and kube-proxy and include extra manifests for metrics-server, kubelet certificate approval, and Gateway API. **Cilium is installed before Flux** because nodes need networking before the GitOps controllers can run. The companion GitOps configuration then provides the steady-state management layer; align its Cilium values and ownership with the bootstrap installation.

The Kubernetes API uses the Talos VIP configured in the control-plane patch. **Current Terraform does not provision HAProxy, an Ubuntu image, or XSLT tuning files.** Those references in older notes describe an earlier design; VM tuning is now native HCL in [vms/nodes.tf](vms/nodes.tf).

Existing-cluster detection checks for local credentials and a successful `kubectl get nodes`, then skips selected phases. It is not a comprehensive check of cluster identity, health, or workload readiness; verify your kubeconfig context before rerunning.

## 🔄 GitOps choices

- **Flux (default):** uses `GITHUB_REPO_OWNER` / `GITHUB_REPO`, branch `main`, path `clusters`, token authentication, `--personal`, and `--private=true`. It writes bootstrap manifests to GitHub and reconciles them in the cluster. Adapt these assumptions before using another repository layout or an organization. See the [companion repository](https://github.com/dmuiX/fluxcd.k8sdev.cloud) and [historical Flux notes](fluxcd/fluxcd.md).
- **ArgoCD (retained alternative):** the script contains an HA install function, but initializes its skip flag to `true` and has **no CLI enable switch**. The [Application example](argocd/deployment.yml) points to a separate `argocd.k8sdev.cloud` repository and contains a `${GITHUB_REPO_OWNER}` placeholder that needs rendering; plain `kubectl apply` does not expand it. Installation and repository credentials need separate review. [ArgoCD notes](docs/argocd.md) document earlier experiments, not the default workflow.
- **Neither:** use `--skip-fluxcd-installation --skip-init-openbao` to stop before those steps. ArgoCD is already skipped. Install and manage the remaining platform services separately.
- **Cloudflare is two separate paths:** `--skip-cloudflare` disables Terraform node DNS records, not the Flux phase's Cloudflare Secrets for cert-manager/external-dns. The default Flux path still requires `CLOUDFLARE_API_TOKEN`.

OpenBao initialization assumes the companion stack exposes HelmReleases named `cilium`, `cert-manager`, `longhorn`, and `openbao` in `flux-system`, plus an `openbao-0` pod. It does not install those services itself. The helper prints sensitive key/initialization output and writes root/recovery credentials to `openbao-credentials.txt`; protect and back up that material.

### OpenBao reruns

**Do not rerun the OpenBao phase with the first-install `OPENBAO_UNSEAL_KEY=""` setting.** The helper generates a new key and applies the unseal Secret **before** checking whether OpenBao is already initialized. Existing-cluster detection does not skip this phase. Replacing the key can prevent automatic unsealing after a restart.

Before a rerun, preserve the original generated key in protected private configuration and independently backed-up recovery custody, or pass `--skip-init-openbao`. Do not generate a replacement key as a troubleshooting step for an initialized instance.

## 📈 Upgrade reference

Upgrades are a separate maintenance operation, not a guaranteed bootstrap feature. Check the [Talos documentation](https://docs.siderolabs.com/) for the supported source/target path and client compatibility. Back up etcd, persistent volumes, and recovery credentials first; plan for quorum and storage replica health. [Earlier upgrade notes](docs/upgrade-cluster.md) record Longhorn trouble, not a validated upgrade runbook.

Preserve the system extensions needed by the workloads. The current bootstrap requests this schematic (the AMD microcode extension is host-specific):

```bash
# Generate a schematic ID for the extensions used by this lab
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
```

For a reviewed maintenance plan, the command shape for **one node at a time** is:

```bash
export TALOSCONFIG=./cluster/talosconfig
talosctl --nodes <one-node-ip> upgrade \
  --image factory.talos.dev/installer/<schematic-id>:v<target-version> \
  --preserve
```

Replace the placeholders, verify the target release's CLI semantics, and check node, etcd, and storage health before proceeding to another node. `--preserve` is not a backup or a guarantee against data loss. Kubernetes upgrades require their own compatibility review.

---

## 📂 File structure

```text
bootstrap-cluster.sh          Main orchestration script
.env                          Local shell configuration + credentials (gitignored)
nodes.yaml                    Generated topology (gitignored)
nodes.yaml.example            Historical topology example, including old HAProxy node
templates/                    Talos control-plane and worker patches
vms/                          Terraform: KVM domains, disks, optional Cloudflare DNS
cluster/                      Generated Talos configs and secrets (gitignored)
argocd/                       Alternative Application example + Gateway API manifest
fluxcd/                       Earlier standalone Flux bootstrap notes/helper
scripts/                      Boot-order and YAML tooling helpers (review before use)
docs/                         Component notes and troubleshooting history
docs/archive/                 Earlier plans and session notes
```

---

## 🔒 Safety and cleanup

**Cleanup destroys data.** Read the implementation and confirm VM names, storage, Terraform state, and backups before using either flag:

| Path | Actual behavior |
| --- | --- |
| `--cleanup-vms` | Reads names from `nodes.yaml`, calls `virsh destroy` and `virsh undefine --remove-all-storage`. Keeps DNS and does not reconcile Terraform state. There is no confirmation prompt in this helper |
| `--cleanup-all` | Runs `terraform destroy` in `vms/`, then deletes local generated Talos configs **including `secrets.yaml`** |
| Exit after an error | Normally asks whether to clean up; confirmation invokes VM-only deletion and removes some generated configs |
| `--no-cleanup` | Disables that exit trap's cleanup; **does not** bypass the `terraform destroy` call after a failed `terraform apply` |

These operations are broader than a Kubernetes reset. Store recovery material outside the affected VMs and repository checkout. Do not use a rerun or cleanup flag as the first diagnostic step for a valuable cluster.

## 🔍 Troubleshooting

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

The container repeatedly exits and Kubernetes backs off before restarting it. Inspect the previous container's logs and termination reason.

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

If VMs stop unexpectedly, confirm whether the host OOM-killer terminated QEMU. Low guest-reported usage alone does not establish that the host has enough memory.

```bash
dmesg | grep -i oom
free -h
virsh list --all
```

Reduce allocations or workloads and leave room for the host. **KSM** (Kernel Same-page Merging) can deduplicate identical pages on suitable hosts, but its effectiveness varies and it has performance/security trade-offs; it is not a substitute for a memory budget.

### GPU VRAM reduces usable host RAM

An integrated GPU may reserve system RAM in firmware. Compare installed RAM with the OS-visible amount before sizing the VMs; reducing an unused graphics reservation may reclaim memory. The exact amount is host-specific.

### Pod can't reach the internet

Check DNS resolution, egress policy, routing, and the host firewall separately.

```bash
kubectl exec -it <pod> -- wget -qO- https://example.com
kubectl logs -n cilium -l k8s-app=cilium --tail=100
```

Check: Cilium NetworkPolicies, CoreDNS running (`kubectl get pods -n kube-system`), host firewall not blocking bridge traffic (`sysctl net.bridge.bridge-nf-call-iptables`).

### Secrets not working

Typos, wrong encoding, or wrong namespace.

```bash
kubectl describe secret <name> -n <ns>  # inspect key names/sizes, not decoded values
```

Check namespace, key names referenced by the Pod, and accidental newlines. Kubernetes `data` values must be Base64-encoded; `stringData` accepts plain strings. Base64 is not encryption. Avoid copying secret values into logs or issue reports.

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

## 🚧 Current limitations

These are observations from the tracked code, not results of a fresh deployment test.

| Area | Current state |
| --- | --- |
| Configuration completeness | No tracked `.env.example`; prompts cover only some inputs. `TALOS_VERSION`, `CILIUM_VERSION`, and several Terraform inputs need explicit configuration |
| Cloudflare skip path | DNS resources are conditional, but `cloudflare_api_token` and `cloudflare_zone_name` remain required Terraform variables without defaults. `--skip-cloudflare` does not remove those declarations or the Flux credential requirement |
| Terraform execution | No backend block is tracked. The configured libvirt URI must be reachable from the Terraform execution environment; `qemu:///system` uses the local host. Earlier Terraform Cloud notes are not current backend configuration |
| Image verification | Existing ISO files are accepted without rechecking. A checksum-download failure warns and continues; independently verify the selected image/checksum pair before use |
| Version selection | The machine patches contain fixed Gateway API URLs and moving `main`/`latest` URLs for other manifests. `GATEWAY_API_VERSION` only affects the ArgoCD function; it does not rewrite the patch URLs |
| Host assumptions | First-bridge selection, a `default` storage pool, fixed CPU topology/`topoext`, AMD microcode, `/24` addressing, and lab time servers need review |
| Reruns | Detection depends on local credentials/current Kubernetes context; topology is still regenerated. The Cilium install path can uninstall existing resources if not skipped. Preserve the original OpenBao unseal key or skip that phase; see [OpenBao reruns](#openbao-reruns) |
| Partial failures | Some node/configuration/readiness failures warn and continue. The final summary does not prove all nodes, GitOps services, or storage are healthy |
| Worker cold boots | Terraform attaches the ISO to all nodes; bootstrap's persistent ISO-ejection loop only visits control planes. Review worker media/boot behavior before relying on restarts |
| Destructive error handling | A failed `terraform apply` invokes `terraform destroy` even with `--no-cleanup`; VM-only cleanup removes storage outside Terraform's state management |
| Earlier design notes | HAProxy, Ubuntu cloud-init, and XSLT tuning references are historical. Current VM resources use native provider attributes, including explicit ACPI/APIC features |

The detailed debugging and lifecycle notes below retain useful project history while distinguishing it from the current implementation.

---

## 🐛 Debug story: Talos VMs without network after the Terraform overhaul

A historical incident retained for its debugging method. The current HCL already includes explicit ACPI/APIC features; this is not a claim that all libvirt 0.9.x deployments have the same problem.

### Symptom

After the Terraform overhaul to `dmacvicar/libvirt ~> 0.9.7` (commit `fe42438`), all Talos VMs came up in maintenance mode but had **no network at all**:

- Talos dashboard: no IP, no hostname, `connectivity: false`, no MAC on the Network page.
- A Windows VM on the **same** bridge `br0` worked fine (DHCP from the LAN).
- The previous Terraform code (older provider, machine type `pc`/i440fx, XSLT-based tuning) had no problem.

### What was checked and ruled out

| Layer | Check | Result |
|---|---|---|
| Tap device | `ip link show vnetXXX` | `UP, LOWER_UP, master br0` ✅ |
| Bridge enslavement | `bridge link show` | tap is slave of `br0` ✅ |
| Bridge / DHCP | Windows VM gets a lease on the same bridge | DHCP server reachable ✅ |
| Generated XML interface block | `virsh dumpxml <vm-name> \| sed -n '/<interface/,/<\/interface>/p'` | `virtio`, `link state='up'`, valid `52:54:00:…` MAC ✅ |
| Host wire activity | `tcpdump -i br0 -e -nn ether host 52:54:00:…` during boot | **zero packets** — no ARP, no DHCP, no IPv6 RS ❌ |
| MAC consistency | TF's `md5(name)` slicing vs. `bootstrap-cluster.sh:get_mac_for_node` | identical ✅ |
| Bridge auto-detect picking the wrong bridge | `br0` is set in virt-manager, tap really is enslaved to it | not the cause ✅ |
| ISO integrity | Stock `metal-amd64.iso` from siderolabs releases (`metal-amd64.iso` SHA256 vs upstream) | matches ✅ |
| Schematic | Used only later in the `installer` image string in [templates/control-node-patch.yaml](templates/control-node-patch.yaml), irrelevant for first boot | not the cause ✅ |
| Talos really is running, on the right tab | Confirmed visually on VNC | yes ✅ |
| Boot order edge cases (`cdrom,hd` falling through to a blank disk) | Talos dashboard is visible, so kernel is alive | not the cause ✅ |
| q35 PCIe controller layout | `virsh dumpxml <vm-name> \| sed -n '/<controller/,/\/controller>/p'` | q35 layout with auto-added `pcie-root-port`s and NIC behind `pci.1`; no obvious topology error ✅ |

The useful clue: **`tcpdump` saw no traffic from the guest**, while host-side checks looked correct. That shifted attention from DHCP configuration toward whether the guest could see the virtual NIC at all.

### The cross-OS sanity check that cracked it

Booting **Alpine standard** in the same VM slot also showed only `lo`. Reproducing the symptom with a second OS made a Talos-specific network configuration problem less likely and directed the investigation toward the virtual hardware.

### Root cause

Looking at the **complete** domain XML (not just the `<interface>` block), one entire element was missing that normally wouldn't even be questioned:

```xml
<!-- This was NOT in the generated XML: -->
<features>
  <acpi/>
  <apic/>
</features>
```

In this q35 setup, missing ACPI prevented the guest from enumerating devices behind the PCIe root ports, including the virtio NIC and disk. The chipset-integrated SATA CDROM still allowed the ISO to boot, making the failure look like a networking problem. The working Windows VM, created separately through virt-manager, had ACPI/APIC enabled.

### Why the old code was fine and the new code wasn't

| | Old (commit `63cd458`) | New (commit `fe42438`) |
|---|---|---|
| Provider | `dmacvicar/libvirt < 0.9` | `dmacvicar/libvirt ~> 0.9.7` (new framework schema) |
| Machine type | not set → libvirt default `pc` (i440fx) | `q35` |
| Tuning | `xml { xslt = optimizations.xsl }` | native attributes |
| `<features>` in generated XML | present in the earlier setup | **absent** in the failing setup |

The migration changed the provider schema, machine type, and tuning representation together. Looking only at the interface block hid the missing domain-level features; comparing the complete domain XML was more useful.

### Fix

The explicit domain-level `features` block is already present in [vms/nodes.tf](vms/nodes.tf), using the current schema:

```hcl
resource "libvirt_domain" "node_domain" {
  # ...

  features = {
    acpi = true
    apic = {}
  }

  # ...
}
```

When reviewing a deployment, verify that its domain XML contains:

```xml
<features>
  <acpi/>
  <apic/>
</features>
```

The project notes record that enabling these features restored NIC visibility and DHCP in the affected setup.

### Lessons

- **When `dumpxml` looks "fine", check what's *missing*, not just what's there.** A missing `<features>` is invisible until you look for it specifically.
- **A cross-OS boot test helps separate guest-specific configuration from virtual hardware problems.** Reproducing the failure with Alpine narrowed the investigation.
- **No packets is a useful clue, not proof on its own.** Validate the capture interface/filter and host bridge, then check whether the guest enumerates the device.
- **When a Terraform provider migration changes more than one thing at once** (provider major version + machine type + schema style), expect at least one regression that hides behind the others.

---

## 💿 Phase 7 lifecycle: from ISO to installed Talos

Boot behavior was a recurring source of confusion in the project. The current implementation, rather than earlier comments or session notes, is the reference:

1. **Initial boot:** [vms/nodes.tf](vms/nodes.tf) attaches the Talos ISO and sets `os.boot_devices` to CDROM then disk for all nodes. The blank-disk VM boots into maintenance mode with a DHCP address.
2. **Discovery and installation:** `phase_bootstrap` matches Terraform's deterministic MAC outputs to `arp-scan` results. It applies per-node configs in parallel with `talosctl apply-config --insecure --mode=reboot` and retries failures. The patches select a factory installer image tagged `:v${TALOS_VERSION}` and configure static addresses; the current VM disk is `vda`.
3. **Persistent media change:** after config application, the script runs `virsh change-media --eject ... --config` for **control planes only**. It does not call `virt-xml` or rewrite the boot order. Persistent media changes affect later starts; they are separate from the running guest's installation progress.
4. **Secure endpoint checks:** the current **Phase 7.2 exists** and polls the control-plane static IPs with authenticated `talosctl version`. Later steps attempt etcd bootstrap, check additional nodes, and retrieve kubeconfig. API reachability alone is not full cluster health.

Earlier project notes describe Talos transitioning with **kexec**, without a complete firmware reboot. That explains why waiting for a fixed number of libvirt power-state transitions was a poor readiness signal. It does **not** mean every `apply-config` return proves installation, reboot, and Kubernetes readiness have completed.

### Diagnostic lessons

- If a node returns to maintenance mode, inspect the installer image tag, extensions, install disk, and installation result before blaming boot-order timing. The notes record a missing `v` prefix as one earlier cause; the current patches add that prefix.
- Do not force-stop a node while installation may be writing to disk. Diagnose the actual endpoint and disk/media state first.
- Check persistent XML as well as the running domain, especially for worker cold boots; the current ejection loop does not cover workers.
- Use explicit readiness checks rather than arbitrary sleeps or assumptions about how many reboots should occur.

Useful read-only checks (replace placeholders):

```bash
virsh dumpxml <vm-name> --inactive
virsh domblklist <vm-name> --details
# With TALOSCONFIG pointing to this cluster:
talosctl --nodes <node-ip> version --client=false
talosctl --nodes <control-plane-ip> service etcd status
```

## 📚 Reference notes

These files preserve the learning process and may contain older versions, local paths, or incomplete instructions. Cross-check them against the current script and provider schema rather than treating them as a deployment checklist.

- [Cilium notes](docs/cilium.md) — earlier networking experiments; the script contains the current bootstrap values.
- [Longhorn notes](docs/longhorn.md) — Talos storage extensions, mounts, and Pod Security considerations.
- [Upgrade notes](docs/upgrade-cluster.md) — maintenance experiments and storage/recovery lessons.
- [No-network investigation](docs/debug-talos-no-network.md) — earlier hypotheses; the resolved historical case is summarized above.
- [HAProxy notes](docs/haproxy.md) — the former Ubuntu/cloud-init design, no longer provisioned here.
- [ArgoCD notes](docs/argocd.md) and [Flux notes](fluxcd/fluxcd.md) — alternative/earlier GitOps setup details.
- [Archived plans and session notes](docs/archive/) — development history, not current operational guarantees.

> AI-assisted development with Claude Code.