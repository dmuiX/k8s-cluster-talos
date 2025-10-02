version: 2
ethernets:
  ens3: # This assumes the interface is named ens3
    dhcp4: no
    addresses:
      - ${ip_address}/24
    gateway4: ${gateway}