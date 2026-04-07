# WIP — wo ich grad stehe

Letzter Commit: `f3f441e` (erster Comment-Sweep + README Prerequisites).
Script: `bootstrap-cluster.sh` bei 1643 Zeilen.

## Offene Tasks (in Reihenfolge)

### 1. Version-Variablen aus Script in .env + README verschieben
User-Anweisung:
> `CILIUM_VERSION="1.19.2"` und `GATEWAY_API_VERSION="v1.4.0"` machen in der `.env` mehr Sinn als im Script. In die README rein damit man weiß das muss im `.env` stehen.

- Fundstellen im Script:
  - `bootstrap-cluster.sh:1386` — `--version "$CILIUM_VERSION"`
  - `bootstrap-cluster.sh:1438` — `${GATEWAY_API_VERSION}` im Gateway-API-URL
- Die Definitionen (Zeilen 7-8) im Script löschen, aus `.env` lesen lassen (`.env` wird in `bootstrap-cluster.sh:580-582` gesourcet).
- Auch die **anderen** Version/URL-Variablen prüfen die sinnvoller in `.env` wären. User-Zitat:
  > "update auch mal die readme was jetzt genau in die .env rein muss wenn du das aus dem script lesen kannst"
- User hat explizit gesagt dieser Block kann **so übernommen werden** (also NICHT in .env verschieben, bleibt im Script):
  ```
  # TALOS
  TALOS_VERSION="1.12.6"
  TALOS_ISO_URL="https://github.com/siderolabs/talos/releases/download/v${TALOS_VERSION}/metal-amd64.iso"
  TALOS_CHECKSUM_URL="https://github.com/siderolabs/talos/releases/download/v${TALOS_VERSION}/sha256sum.txt"
  METALISO_ABSOLUTE_PATH="${VMS_DIR}/metal-amd64.iso"

  # Ubuntu
  UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/resolute/20260328/resolute-server-cloudimg-amd64.img"
  UBUNTU_CHECKSUM_URL="https://cloud-images.ubuntu.com/resolute/20260328/SHA256SUMS"
  UBUNTU_IMAGE_PATH="/var/lib/libvirt/images/resolute-server-cloudimg-amd64.img"
  ```
- README-Abschnitt `## 🔑 \`.env\` Variables` (ab Zeile 124) muss um die neuen Variablen ergänzt werden.

### 2. Zweiter Comment-Sweep (war unterbrochen)
User-Freigabe: "lass grenzfälle drin" — d.h. nur reine "was"-Kommentare löschen.

Löschen in `bootstrap-cluster.sh` (zweite Hälfte, Zeilen ~797-1607):
- 797-800: Step 0 Header-Block
- 832-837: Step 1 Header
- 876-880: Step 2 Header
- 897-905: apt-Paket-Liste (redundant zum Array)
- 939-944: Step 3 Header
- 1011-1023: Step 4-5 Header
- 1044-1057: Steps 6-9 Header
- 1143-1146: Step 7 Header
- 1266-1268: Step 8 Header
- 1287-1288: Step 8a Header
- 1346-1348: Step 10 Header
- 1427-1429: Step 11 Header
- 1466: Step 12 Header
- diverse triviale Inline-Kommentare ("# Verify X was done" etc.)

**Behalten (why-Kommentare):**
- 1195-1223: virt-xml Boot-Order Rationale + alte Phase-7.2-Notiz
- 1371-1372: Cilium Cleanup Preservation Marker (siehe `memory/feedback_cilium_cleanup.md`)
- OpenBao pipefail/wget why-Kommentare
- yq envsubst Workaround-Block
- `--mode=reboot` Rationale

### 3. Git
- Lokales `main` ist divergiert: 7 ahead, 1 behind origin. User muss `git pull --rebase origin main` machen.
- Niemals `git push` ausführen — User pusht manuell (siehe `memory/feedback_push.md`).

## Letzte User-Message vor Stop
> "okay stop" — nachdem er Version-Variablen-Task gegeben hat. Task 1 war noch nicht angefangen.
