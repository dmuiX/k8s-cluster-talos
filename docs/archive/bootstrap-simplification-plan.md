# bootstrap-cluster.sh simplification plan

The script is 1945 lines. Below are the concrete, ranked opportunities to reduce it, plus things that look removable but should stay. Written after an explorer pass on 2026-04-07.

## Ground rules (read before touching anything)

- The Phase 7 kexec model is documented in [README.md](../README.md#phase-7-bootstrap-sequence--what-actually-happens-and-why). Do not reintroduce wait-for-reboot loops, `virsh destroy` after `apply-config`, or any "ride out the reboots" logic. Phase 7.2 was just deleted for exactly this reason.
- Do not merge phases that have legitimately independent skip flags (`--skip-iso-download`, `--skip-terraform`, etc.) — granularity has real value.
- Before deleting any defensive block, check `git log -p` for *why* it was added. "Looks over-defensive" and "actually defends against a real past incident" look identical until you read the commit history.

## Priority 1 — safe wins, do first

### 1a. Factor repeated `yq` queries into 2 helpers (~15 lines)

The same node-lookup patterns appear 6+ times at roughly lines 1200, 1446, 1484, 1912, 1916–1918:

```bash
get_ips_by_role()  { yq e ".nodes[] | select(.role == \"$1\") | .ip"        "$NODES_FILE_PATH"; }
count_by_role()    { yq e "[.nodes[] | select(.role == \"$1\")] | length"   "$NODES_FILE_PATH"; }
```

- **Why safe:** pure read-only, no behavior change.
- **Risk:** none — sed-level refactor, easy to eyeball.
- **Test:** normal bootstrap run completes.

### 1b. Batch the apt installs (~15 lines)

[bootstrap-cluster.sh:1010-1028](../bootstrap-cluster.sh#L1010-L1028) runs `apt-get update` separately for yq, jq, curl, arp-scan, genisoimage, openssl. Collapse to one:

```bash
apt-get update && apt-get install -y yq jq curl arp-scan genisoimage openssl
```

Leave the HashiCorp and Helm repo setup as-is — those are one-off third-party repos with their own key/source dance.

- **Why safe:** identical outcome, fewer network round-trips.
- **Risk:** none.

## Priority 2 — needs archaeology before deciding

### 2a. Cilium pre-install cleanup block (~20 lines, conditional)

Lines ~1557–1575 do: helm uninstall → cilium CLI uninstall → force-delete namespace, *before* the install.

- **Before touching:** run `git log -p -- bootstrap-cluster.sh` and find the commit that added this block. Read the commit message.
  - If the message is "add cleanup for re-runs" / "be safe" → delete the block, let Helm's idempotence handle it.
  - If the message references a specific incident (stuck finalizer, dangling webhook, orphaned CRD) → **keep it**, and add a comment on the block explaining which incident it defends against so the next round doesn't rip it out.
- **Risk if wrong:** re-runs of `phase_install_cilium` fail in a weird half-installed state that's hard to debug.

### 2b. Structural pass on banners / progress spinners (unknown lines, potentially large)

A 1945-line bash script often has 200+ lines of `echo "━━━…"` banners and `Waiting for X ✓ (0s)` spinner ceremony. Before deciding:

1. Measure it: `grep -c '━━━' bootstrap-cluster.sh` and `grep -c 'Waiting for' bootstrap-cluster.sh`.
2. If the ceremony is ≥10% of the file, introduce two helpers:
c   ```bash
   section() { printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n%s\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' "$1"; }
   wait_for() { local label=$1 cmd=$2 max=${3:-60}; ... }
   ```
3. If the ceremony is <10%, skip this — not worth the churn.
- **Risk:** cosmetic, but spinner output format changes — users see slightly different progress text.

## Do NOT do these (explorer suggested them, they're wrong)

- **Remove `|| true` from cleanup paths** — cleanup runs from an `EXIT` trap during error handling. If `virsh destroy` fails because the VM is already gone, the cleanup itself must not blow up mid-abort. The `|| true` is correct.
- **Merge `phase_download_images` and `phase_create_vms`** — they need independent skip flags. Re-downloading ISOs without re-running Terraform is a real workflow.
- **Remove arp-scan discovery retry loop** — DHCP boot is legitimately slow on first run, the 2-minute window is earned.
- **Remove HAProxy port wait** — first-run race against HAProxy coming up.
- **Remove Flux GitRepository reconciliation retry** — bootstrap returns before Flux processes the GitRepository; the retry is real.

## Expected total savings

- Priority 1: ~30 lines, ~1 hour work, near-zero risk.
- Priority 2a: ~20 lines *if* archaeology says it's safe.
- Priority 2b: potentially 100+ lines *if* the banner/spinner count justifies it.

Realistic floor: 30 lines. Realistic ceiling: ~150 lines (≈8% of the file). The script is not "freaking huge" because of one bloated section — it's huge because it does a lot of things, and the real wins are helpers that collapse repetition, not deletion.

## Checklist before any of this lands

- [ ] `bash -n bootstrap-cluster.sh` passes (syntax check).
- [ ] `shellcheck bootstrap-cluster.sh` shows no new warnings.
- [ ] Full bootstrap run from clean state completes successfully.
- [ ] Re-run with `--skip-*` flags still works (idempotence preserved).
- [ ] Phase 7 still follows the kexec model documented in README.
