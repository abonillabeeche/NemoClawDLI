#cloud-config
# SAIF NemoClaw lab VM. Rendered by create-vm.sh (file and variable placeholders are filled there).
hostname: @@NAME@@
users:
  - name: labadmin
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - @@SSH_PUBKEY@@
package_update: true
packages: [docker.io, nginx, python3-websockets, tmux, jq, curl, git, qemu-guest-agent]
swap:
  filename: /swapfile
  size: 8G
write_files:
  - path: /etc/saif/lab.env
    permissions: "0644"
    content: |
      SAIF_LLM_URL=@@LLM_URL@@
      SAIF_LLM_MODEL=@@LLM_MODEL@@
      SAIF_SANDBOX=@@SANDBOX@@
      NEMOCLAW_INSTALL_REF=@@NEMOCLAW_REF@@
      SAIF_SITE_TARBALL=@@SITE_TARBALL@@
  - path: /etc/nginx/saif.htpasswd
    permissions: "0640"
    content: |
      @@HTPASSWD@@
  - path: /etc/nginx/sites-available/saif
    content: |
@@FILE:nginx-saif.conf@@
  - path: /opt/saif/agent_shim.py
    permissions: "0755"
    content: |
@@FILE:agent_shim.py@@
  - path: /usr/local/bin/saif-install-nemoclaw
    permissions: "0755"
    content: |
@@FILE:saif-install-nemoclaw@@
  - path: /usr/local/bin/saif-update-course
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # Refresh the branded course from the fork's Pages tarball.
      set -euo pipefail
      . /etc/saif/lab.env
      tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
      curl -fsSL --retry 5 "$SAIF_SITE_TARBALL" -o "$tmp/site.tgz"
      mkdir -p "$tmp/site" && tar -xzf "$tmp/site.tgz" -C "$tmp/site"
      sudo rm -rf /var/lib/saif-course/site.new && sudo mv "$tmp/site" /var/lib/saif-course/site.new
      sudo chmod -R a+rX /var/lib/saif-course/site.new
      sudo rm -rf /var/lib/saif-course/site && sudo mv /var/lib/saif-course/site.new /var/lib/saif-course/site
      echo "course updated from $SAIF_SITE_TARBALL"
  - path: /etc/systemd/system/saif-agent-shim.service
    content: |
      [Unit]
      Description=SAIF launchable-compatible agent endpoints (/api/agent, /ws/terminal)
      After=network-online.target docker.service
      [Service]
      User=labadmin
      EnvironmentFile=/etc/saif/lab.env
      Environment=PATH=/home/labadmin/.local/bin:/home/labadmin/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
      ExecStart=/usr/bin/python3 /opt/saif/agent_shim.py
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [usermod, -aG, docker, labadmin]
  - [chown, "root:www-data", /etc/nginx/saif.htpasswd]
  - [mkdir, -p, /var/lib/saif-course/site]
  - [sh, -c, "echo '<h1>SAIF course not downloaded yet</h1><p>run saif-update-course</p>' > /var/lib/saif-course/site/index.html"]
  - [sh, -c, "su - labadmin -c saif-update-course || true"]
  - [rm, -f, /etc/nginx/sites-enabled/default]
  - [ln, -sf, /etc/nginx/sites-available/saif, /etc/nginx/sites-enabled/saif]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, qemu-guest-agent, docker, saif-agent-shim]
  - [systemctl, reload, nginx]
