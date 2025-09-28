#cloud-config
version: 2
ethernets:
  eth0: # This assumes the interface is named eth0
    dhcp4: no
    addresses:
      - ${ip_address}/24
    gateway4: ${gateway}
    nameservers:
      addresses:
        ${join(", ", nameservers)}

package_update: true
packages:
  - haproxy

write_files:
  - path: /etc/haproxy/haproxy.cfg
    permissions: '0644'
    content: |
      global
          log /dev/log    local0
          log /dev/log    local1 notice
          chroot /var/lib/haproxy
          stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
          stats timeout 30s
          user haproxy
          group haproxy
          daemon

      defaults
          log     global
          mode    http
          option  httplog
          option  dontlognull
          timeout connect 5000
          timeout client  50000
          timeout server  50000

      frontend kubernetes-api
          bind *:6443
          mode tcp
          option tcplog
          default_backend kubernetes-api-backend

      backend kubernetes-api-backend
          mode tcp
          balance roundrobin
          %{ for node in control_nodes ~}
          server ${node.name} ${node.ip}:6443 check
          %{ endfor ~}

runcmd:
  - [ systemctl, enable, --now, haproxy ]
