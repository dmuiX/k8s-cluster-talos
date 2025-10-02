#cloud-config
package_update: true
package_upgrade: true
reboot_if_required: true

growpart:
  mode: auto
  devices: ['/']

resize_rootfs: true

packages:
  - haproxy
  - unattended-upgrades
  - ssh-import-id

chpasswd:
  expire: false
  users:
    - {name: "${username}", password: "${user_password}", type: text}

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

  - path: /etc/apt/apt.conf.d/50unattended-upgrades
    content: |
      Unattended-Upgrade::Allowed-Origins {
        "$${distro_id}:$${distro_codename}";
        "$${distro_id}:$${distro_codename}-security";
        "$${distro_id}ESMApps:$${distro_codename}-apps-security";
        "$${distro_id}ESM:$${distro_codename}-infra-security";
        "$${distro_id}:$${distro_codename}-updates";
        "$${distro_id}:$${distro_codename}-proposed";
        "$${distro_id}:$${distro_codename}-backports";
      };
      Unattended-Upgrade::Automatic-Reboot "true";
      Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
      Unattended-Upgrade::Remove-Unused-Dependencies "true";
      Unattended-Upgrade::Mail "root";
      Unattended-Upgrade::MailOnlyOnError "true";

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Download-Upgradeable-Packages "1";
      APT::Periodic::AutocleanInterval "7";
      APT::Periodic::Unattended-Upgrade "1";

runcmd:
  # Lock the root password to disable password login for root
  - passwd -l root

  # Disable root SSH login and password authentication in sshd config
  - sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
  - sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
  - systemctl restart sshd

  # Clone dotfiles repo
  - sudo -u ${username} -H sh -c "git clone https://github.com/dmuiX/dotnet-files-linux.git /home/${username}/.dotfiles || true"

  # Copy dotfiles
  - sudo -u ${username} -H sh -c "cp /home/${username}/.dotfiles/.* /home/${username}/ 2>/dev/null || true"

  # Make setup.sh executable explicitly
  - sudo -u ${username} -H sh -c "chmod +x /home/${username}/.dotfiles/setup.sh"

  # Run setup.sh with nice logging
  - sudo -u ${username} -H sh -c "/home/${username}/.dotfiles/setup.sh >> /home/${username}/setup.log 2>&1"

    # Activate unattended-upgrades
  - systemctl enable unattended-upgrades
  - systemctl start unattended-upgrades

  - systemctl enable haproxy
  - systemctl start haproxy

    # Reboot to make the system restart required message go away
  - reboot now

users:
  - default
  - name: ${username}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /usr/bin/zsh
    ssh_import_id: ['gh:dmuiX']
    groups: sudo
