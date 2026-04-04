
export TALOSCONFIG=/home/nasadmin/k8s-cluster-talos/cluster/talosconfig; talosctl upgrade-k8s -n control-node-1 --to 1.34.6 --dry-run
export TALOSCONFIG=/home/nasadmin/k8s-cluster-talos/cluster/talosconfig; talosctl upgrade-k8s -n control-node-1 --to 1.35.0 --dry-run

seems like this worked

but now longhorn is broken

i suppose the update did not set the necessary plugins

and this

When upgrading a Talos Linux node, always include the --preserve option in the command. This option explicitly tells Talos to keep ephemeral data intact.

Example:

talosctl upgrade --nodes 10.20.30.40 --image ghcr.io/siderolabs/installer:v1.7.6 --preserve

    Caution: If you do not include the --preserve option, Talos wipes /var/lib/longhorn, destroying all replicas stored on that node.

# this is the way upgrade talos

```bash

SCHEMATIC_ID=$(curl -sX POST "https://factory.talos.dev/schematics" \
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

echo "Schematic ID: $SCHEMATIC_ID"
TALOS_VERSION="v1.12.6"
NODES=("192.168.1.21" "192.168.1.22" "192.168.1.23")

for NODE in "${NODES[@]}"; do
  echo "==> Upgrading $NODE..."
  talosctl upgrade --nodes $NODE --image factory.talos.dev/installer/${SCHEMATIC_ID}:${TALOS_VERSION} --preserve
  echo "==> $NODE done. Warte 10s vor dem nächsten Node..."
  sleep 10
done

echo "==> Alle Nodes upgraded"
```

wenn kommt waiting for actor ID
einfach warten! Das kommt dann schon.

# k8s upgrades

export TALOSCONFIG=/home/nasadmin/k8s-cluster-talos/cluster/talosconfig; talosctl upgrade-k8s -n control-node-1 --to 1.34.6 --dry-run
export TALOSCONFIG=/home/nasadmin/k8s-cluster-talos/cluster/talosconfig; talosctl upgrade-k8s -n control-node-1 --to 1.35.0 --dry-run

# nachstes mal backup der vms machen

dann hab ich das ding schneller wieder her gestellt
es geht immer was schief bei sowas gerade weil ichs das erste mal mache ey

so jetzt 2 optionen

1. komplett neu aufsetzen und restore mit k8up testen
2. eine vm neu erstellen oder irgendwie wiederherstellen
hab aber geradne kein zugriff mehr auf die secrets und co aus dem vorherigen cluster

wenn k8up backup schief ging oder geht dann sei es so dann sind die daten halt weg viel war eh nich drin

bisschen logs
bisschen opencost stuff
und meine secrets aber die kann ich ja wieder herstellen.

zudem vorteil ich habs jetzt dann schon einmal gemacht

also mal sehen.

ich machs jetzt nimmer morgen vlt

oder ich lass den cluster nochmal herstellen jetzt is auch ne idee mit dem boostrap
