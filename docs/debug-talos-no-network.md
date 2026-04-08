# Talos VMs ohne Netzwerk nach Terraform-Overhaul

## Symptom
- Nach dem Overhaul ([fe42438](../../../commit/fe42438)) bekommen die Talos-VMs im Maintenance-Mode keine Netzwerkverbindung.
- Talos-Dashboard zeigt: keine IP, kein Hostname, `connectivity: false`, keine MAC-Adresse auf der Network-Seite.
- Mit dem alten Libvirt-Provider und der alten `nodes.tf` lief es problemlos.
- Eine Windows-VM auf derselben Bridge (`br0`) funktioniert weiterhin per DHCP.

## Was geprüft wurde (alles OK)

### Host-Seite
- `ip link show vnet195`: `<BROADCAST,MULTICAST,UP,LOWER_UP> ... master br0 state UNKNOWN` → Tap ist up, hat Carrier, korrekt an `br0` enslaved.
- `virsh domiflist control-node-1` zeigt das Tap an `br0` mit `virtio`.

### Generiertes Domain-XML
```xml
<interface type='bridge'>
  <mac address='52:54:00:04:87:5d'/>
  <source bridge='br0'/>
  <target dev='vnet195'/>
  <model type='virtio'/>
  <link state='up'/>
  <alias name='net0'/>
  <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
</interface>
```
Sieht oberflächlich identisch zur Windows-VM aus. **Aber:** der NIC sitzt auf `bus='0x01'`, also hinter einem `pcie-root-port` — das ist q35-typisch, im alten Setup mit `pc`/i440fx wäre der NIC auf `bus='0x00'` direkt am Legacy-PCI gewesen.

### PCIe-Controller-Topologie
`virsh dumpxml control-node-1` (Controller-Auszug):
```xml
<controller type='pci' index='0' model='pcie-root'>
  <alias name='pcie.0'/>
</controller>
<controller type='pci' index='1' model='pcie-root-port'>
  <target chassis='1' port='0x10'/>
  <alias name='pci.1'/>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0' multifunction='on'/>
</controller>
<!-- pci.2 … pci.6: weitere pcie-root-ports an slot 0x02 function 0x1..0x5 -->
<controller type='usb' index='0' model='qemu-xhci'>
  <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
</controller>
<controller type='sata' index='0'>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x1f' function='0x2'/>
</controller>
<controller type='virtio-serial' index='0'>
  <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
</controller>
```

Das ist **stink-normales Standard-q35-Setup**. libvirt hat 6 `pcie-root-port`s automatisch angelegt, der virtio-NIC sitzt auf `bus='0x01'` = `pci.1` (der erste Root-Port). Topologisch absolut nichts auffällig — jede q35-VM sieht so aus, auch funktionierende. Damit ist die Sub-Hypothese „PCIe-Topologie kaputt / fehlende Root-Ports" **ausgeschlossen**.

Was die q35-These dadurch zwar schwächt aber nicht killt: es bleibt trotzdem die einzige Variable die sich gegenüber dem funktionierenden Stand geändert hat.

### Bridge / DHCP
- DHCP auf `br0` funktioniert (Windows-VM bekommt eine Lease).
- `tcpdump -i br0 -e -nn ether host 52:54:00:04:87:5d` während Talos-Boot/Reboot: **gar nichts**. Kein DHCPDISCOVER, kein ARP, kein IPv6 Router Solicitation. Talos sendet schlicht nichts aufs Netz.

### ISO
- [bootstrap-cluster.sh:111-197](../bootstrap-cluster.sh#L111-L197) `download_and_verify` macht Checksum-Verifikation, **aber nur direkt nach Download**. Existiert die Datei schon (Zeile 127-130), wird sie nie wieder geprüft. Manuell verifizieren:
  ```bash
  sha256sum /path/to/metal-amd64.iso
  curl -sL https://github.com/siderolabs/talos/releases/download/v1.12.6/sha256sum.txt | grep metal-amd64.iso
  ```
- Der Schematic ([bootstrap-cluster.sh:203-213](../bootstrap-cluster.sh#L203-L213)) ist für Erst-Boot **irrelevant** — die Boot-ISO ist die Stock-`metal-amd64.iso`, der Schematic geht erst in den `installer`-Image-String im Patch ([templates/control-node-patch.yaml:3](../templates/control-node-patch.yaml#L3)) und wird damit erst *nach* erfolgreichem `apply-config` gezogen.

## Root Cause (Hypothese)

Diff alt → neu in [vms/nodes.tf](../vms/nodes.tf):

| Aspekt | Alt (Commit 63cd458) | Neu (Commit fe42438) |
|---|---|---|
| Provider | dmacvicar/libvirt < 0.9 | dmacvicar/libvirt ~> 0.9.7 |
| `os.type_machine` | nicht gesetzt → libvirt-Default `pc` (i440fx) | **`q35`** |
| Tweaks | per `xml.xslt = optimizations.xsl` | nativ als Attribute |
| Network-Block | `network_interface { bridge, mac, addresses, hostname }` mit `addresses` und `hostname` (DHCP-Hint via libvirt-dnsmasq) | `interfaces = [{ source.bridge.bridge, mac.address, model.type, link.state }]` ohne `addresses`/`hostname` |

Die alte `optimizations.xsl` hat **nichts** am `<interface>` geändert — nur iothreads, hpet, CPU-Topologie. Die sind in der neuen `nodes.tf` alle nativ abgebildet. Damit ist der einzige netzwerkrelevante Unterschied:

**Maschinentyp ist von `pc` (i440fx) auf `q35` gewechselt.**

Das passt zum dumpxml: NIC auf `bus='0x01'` hinter einem PCIe-Root-Port statt auf Legacy-PCI `bus='0x00'`. Warum genau das Talos's virtio_net dazu bringt, **gar kein** Interface zu enumerieren während Windows weiter funktioniert — nicht final geklärt. Mögliche Unterhypothesen:

1. Auto-platzierter `pcie-root-port` ist hot-pluggable und Talos's frühe Init überspringt ihn.
2. q35 ohne explizit definierte `pcie-root-port`-Controller → libvirt platziert das Device an einer Stelle die der Talos-Kernel nicht sauber enumeriert.
3. Modern-only virtio (non-transitional) auf q35 in Kombination mit irgendeiner ROM-Sache.

## Was ausgeschlossen wurde
- ❌ Bridge-Auto-Detection im Bootstrap-Skript ([bootstrap-cluster.sh:663](../bootstrap-cluster.sh#L663)) erwischt eine falsche Bridge — `br0` ist im virt-manager hart konfiguriert und Tap ist auch tatsächlich Slave von `br0`.
- ❌ Link admin-down — XML hat `<link state='up'/>`, Tap zeigt `LOWER_UP`.
- ❌ Falsche MAC / MAC-Mismatch zwischen TF und Bash — `md5(name)`-basierter Algo ist in [vms/nodes.tf:85](../vms/nodes.tf#L85) und [bootstrap-cluster.sh:357-361](../bootstrap-cluster.sh#L357-L361) identisch.
- ❌ Kein DHCP-Server auf der Bridge — Windows bekommt Leases.
- ❌ Schematic / Custom-ISO ohne virtio_net — Boot-ISO ist Stock `metal-amd64.iso`.
- ❌ XSLT-Migration hat etwas Netzwerkrelevantes verloren — XSLT touched `<interface>` nicht.

## Nächste Schritte (in Reihenfolge der Aufwand/Ertrag)

1. **`type_machine = "q35"` aus [vms/nodes.tf:114](../vms/nodes.tf#L114) entfernen** (oder auf `"pc"` setzen), `terraform apply`, VM neu booten. Wenn Talos jetzt eine MAC im Dashboard zeigt und DHCPt → Hypothese bestätigt, fertig. Das ist der wahrscheinlichste Fix.
2. Wenn das nicht hilft: kleine Live-Linux-ISO (Alpine standard, ~60 MB) im selben VM-Slot booten. `ip link` und `ip addr` checken.
   - Alpine sieht den NIC + DHCPt → Talos-spezifisches Problem (ISO-Hash prüfen, Talos-Version wechseln).
   - Alpine sieht den NIC auch nicht → das XML lügt; PCIe-Topologie defekt. Dann Output von `sudo virsh dumpxml control-node-1 | sed -n '/<controller/,/\/controller>/p'` analysieren.
3. Falls q35 zwingend bleiben soll: explizite `pcie-root-port`-Controller in der `devices`-Block-Definition setzen und den Interface-Block per `address`-Attribut an einen davon binden.
4. ISO-Verify-Logik in [bootstrap-cluster.sh:127-130](../bootstrap-cluster.sh#L127-L130) so anpassen, dass der Hash auch bei existierender Datei einmal geprüft wird. Verhindert einen ähnlichen Stolperstein wenn mal ein halb-runtergeladenes ISO im Cache liegt.
