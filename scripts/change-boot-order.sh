#!/bin/bash

# --- Configuration ---
# List of virtual machines to modify.
VMS="control-node-1 control-node-2 control-node-3 worker-node-1 worker-node-2 haproxy"

# --- Script Logic ---

# Ensure you have a backup before running!
echo "This script will modify the configuration of several VMs."
echo "It is highly recommended to back up your VM definitions first."
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

for vm in $VMS; do
  echo "--- Processing VM: $vm ---"

  # Define the temporary file path
  TMP_XML="/tmp/${vm}.xml"

  # 1. Export the current XML configuration to a temporary file
  virsh dumpxml "$vm" > "$TMP_XML"

  if [ $? -ne 0 ]; then
    echo "Error: Failed to dump XML for $vm. Skipping."
    continue
  fi

  # 2. Use sed to modify the XML file in-place
  #    - First sed command: Deletes any existing <boot dev='...'/> lines inside the <os> block.
  #    - Second sed command: Inserts <boot dev='hd'/> on a new line just before the closing </os> tag.
  sed -i '/<os>/,/<\/os>/ { /<boot dev/d }' "$TMP_XML"
  sed -i "/<\/os>/i \ \ \ \ <boot dev='hd'\/>" "$TMP_XML"

  echo "Updated XML for $vm to boot from 'hd'."

  # 3. Re-define the VM with the modified configuration
  virsh define "$TMP_XML"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to define new configuration for $vm."
  else
    echo "Successfully updated boot order for $vm."
  fi

  # 4. Clean up the temporary file
  rm "$TMP_XML"
done

echo "---"
echo "Script finished. Remember to shut down and restart the VMs for changes to take effect."
