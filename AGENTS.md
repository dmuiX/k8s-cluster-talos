# AGENTS.md

Repository guidance for AI/code assistants.

## Project

Automated Talos Linux Kubernetes cluster deployment on KVM/libvirt.
Single orchestration script (`bootstrap-cluster.sh`) drives the full lifecycle.

Main technologies:

- Talos Linux v1.11.2 / Kubernetes v1.34.1
- KVM/libvirt via Terraform (Terraform Cloud backend)
- Cloudflare DNS (Terraform provider v5)
- HAProxy as load balancer (Ubuntu cloud-init)
- Cilium CNI, ArgoCD / FluxCD (GitOps), OpenBao (secrets)
- Bash + HCL + YAML — no build tools, no package managers

## File Structure

```
bootstrap-cluster.sh          – Main orchestration script (single entry point)
nodes.yaml                    – Cluster topology: node names, IPs, resources
templates/                    – Talos machine config patches (control + worker)
vms/                          – Terraform: KVM domains, HAProxy, Cloudflare DNS
cluster/                      – Generated Talos configs (gitignored)
argocd/                       – ArgoCD Application manifest + repo secret setup
fluxcd/                       – FluxCD alternative bootstrap
scripts/                      – Helpers: boot order, YAML validation, pre-commit
docs/                         – Component docs: Cilium, Longhorn, ArgoCD, etc.
.env                          – Credentials/env vars (gitignored, never commit)
```

## Bootstrap Flow

```
bootstrap-cluster.sh
  ├─ Download Talos/Ubuntu ISOs (with SHA256 verification + retries)
  ├─ terraform apply  →  creates KVM VMs + Cloudflare DNS records
  ├─ talosctl gen-config  →  generates controlplane.yaml / worker.yaml
  ├─ Apply Talos configs to all nodes (parallel, with retry)
  ├─ talosctl bootstrap  →  etcd + control plane init
  ├─ Install Cilium CNI
  ├─ Install metrics-server, gateway-api, kubelet-cert-approver
  ├─ Install ArgoCD or FluxCD
  ├─ Initialize OpenBao (optional)
  └─ cleanup_on_error()  →  terraform destroy or VM-only cleanup on failure
```

## General Principles

- Clarity over cleverness.
- Prefer editing existing files over creating new ones.
- Keep Bash functions focused and small — one responsibility each.
- No new dependencies without a clear reason.
- Bash: always quote variables, use `set -euo pipefail` patterns.

## Bash / Script Rules

- All credentials come from `.env` (sourced at start) — never hardcode them.
- Use `talosctl`, `kubectl`, `terraform` as the authoritative CLIs — no curl workarounds if a proper CLI exists.
- Retry logic belongs in helper functions (`apply_config_with_retry`, `kubectl_retry`) — not inlined.
- Background jobs: track PIDs explicitly and check exit codes with `wait $pid` — avoid temp files for failure detection.
- Avoid pipe subshell traps: use heredoc `<<< "$var"` or process substitution `< <(cmd)` when loop variables must be visible outside.

## Security

- `.env`, `cluster/`, `argocd/github-secret.yaml` are gitignored — never force-add them.
- Never hardcode IPs, tokens, or passwords in committed files.
- Talos machine configs contain private keys — treat as secrets, regenerate if exposed.

## Commit Style

Use Conventional Commits:

- `feat:` new feature or phase in bootstrap
- `fix:` bug fix
- `refactor:` restructuring without behavior change
- `chore:` config, .gitignore, tooling
- `docs:` documentation only

One commit per logical change. No Co-Author lines in commits.

Dont touch files that stand in .gitignore
## What Not To Do

- No CDN calls or external package installs during bootstrap.
- No `--no-verify` on git commits.
- No `terraform destroy` as first response to errors — use `cleanup_vms_only` where possible.
- No hardcoded secrets in any committed file.
- No broad rewrites — small focused edits only.
- No Co-Author in Git commits!
- DO NOT READ .env!
- 
