---
name: bootstrap-cluster.sh Phase 7.2 — Talos install + boot order
description: Open investigation/plan for Phase 7.2 of bootstrap-cluster.sh — fixing nodes ending up in maintenance mode after install. Includes the two-reboot theory, the simplification plan, and the diagnostic state.
type: project
---

# Phase 7.2 of bootstrap-cluster.sh — open work

## Symptom (2026-04-07)
After running `bootstrap-cluster.sh`, all control nodes ended up in maintenance mode (booting from ISO instead of disk). User called this a regression.

## What we know for sure
- Commit `49980a7` ("revert Phase 7.2 to simple shutdown/boot-order/start sequence") removed previously-working polling logic, claiming the v-prefix image fix (`d3415a8`) made it unnecessary. **The v-prefix fix was already in place when the simple version failed**, so 49980a7's premise was wrong (or at least incomplete).
- Old failing output showed `done (0s)` — meaning `talosctl version --insecure` failed on the very first probe in Phase 7.2. The script then immediately shut down a VM whose disk install had not completed → blank disk → next boot falls back to ISO → maintenance mode.
- libvirt's `on_reboot` defaults to `restart` in this repo (only `on_crash` is overridden in `vms/optimizations.xsl`). So any guest-triggered reboot races with libvirt auto-restarting the VM.

## What we are GUESSING (not yet verified)
- That `apply-config --mode=reboot` in maintenance mode causes TWO reboots (Reboot 1 immediate, then installer, then Reboot 2 post-install). This theory comes from comments in pre-49980a7 code, written by an earlier Claude session — could be wrong.
- That `talosctl version --insecure` keeps working during installation. Alternative theory: `--insecure` stops working immediately after `apply-config` because the node is no longer in pure maintenance mode.
- Either theory explains `done (0s)`, but they imply different fixes.

## Current state of bootstrap-cluster.sh (uncommitted)
Phase 7.2 has been rewritten with:
1. **Step a** — wait up to 120s for `talosctl --insecure` to RESPOND on dyn_ip (ride out Reboot 1)
2. **Step b** — wait up to 300s for it to STOP responding (Reboot 2 = install done)
3. `virsh destroy` immediately (not `virsh shutdown` — guest is mid-reboot, won't ACK ACPI; also we need to win the race against libvirt's `on_reboot=restart`)
4. Wait for `domstate` to become non-running
5. `virt-xml --edit --boot hd,cdrom`
6. **Boot order verification** — `virsh dumpxml | grep '<boot dev='` and confirm `hd` is first
7. `virsh start`

**Diagnostic logging is currently embedded** in Phase 7.2: every probe logs timestamp + `talosctl=up/down` + `domstate=...`. The next bootstrap run will produce a per-node timeline that validates or refutes the two-reboot theory.

## Plan (in order)
1. **Diagnostic run** — run bootstrap once with current code, capture Phase 7.2 output. Look at:
   - Initial state at t=0 (already down? = Reboot 1 happened before we looked)
   - Whether step a ever sees `talosctl=up` (validates --insecure works during install)
   - Whether `domstate` ever flips to `shut off` mid-loop without us calling destroy (= libvirt auto-restart race)
   - Time between step a done → step b done (real installer duration)
2. **Simplify based on data** — user and Claude agreed that two reboots aren't needed. The minimal lifecycle is: ISO maintenance → apply-config → installer writes disk → power off → change boot order → power on. The plan is to switch `apply_config_with_retry` (line ~406) from `--mode=reboot` to `--mode=no-reboot`, then collapse Phase 7.2 to roughly:
   ```bash
   sleep 90               # let installer finish writing to disk
   virsh destroy $name    # clean power off, no race
   virt-xml --edit --boot hd,cdrom
   # verify hd is first
   virsh start $name      # boots from disk
   ```
3. **Optional belt-and-suspenders** — set `on_reboot=destroy` in `vms/optimizations.xsl` so any guest-triggered reboot just powers off the VM cleanly, eliminating the auto-restart race entirely. Add a template next to the existing `on_crash` template.
4. **Commit message must be explicit** — when committing the fix, the message MUST call out that 49980a7's premise was wrong, otherwise someone will revert this again. Suggested wording is in the chat history. Key point: the polling/install-wait logic is NOT a workaround for the v-prefix bug; it exists because Talos installation in maintenance mode takes real time and we cannot shut down the VM mid-install.

## Files involved
- `bootstrap-cluster.sh` lines ~1326–1425 (Phase 7.2)
- `bootstrap-cluster.sh` lines ~396–417 (`apply_config_with_retry`, where `--mode=reboot` lives)
- `vms/optimizations.xsl` (where `on_reboot=destroy` would be added)

## Why this matters
This is the third or fourth iteration on Phase 7.2. Each time it gets "simplified" without understanding *why* the complexity was there, the bug comes back. Pin down the actual Talos behavior with the diagnostic run before the next round of changes — stop theorizing.