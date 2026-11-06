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
packages: [docker.io, binutils, nginx, python3-websockets, tmux, jq, curl, git, qemu-guest-agent]
swap:
  filename: /swapfile
  size: 8G
write_files:
  - path: /etc/saif/lab.env
    permissions: "0644"
    content: |
      SAIF_LLM_URL=@@LLM_URL@@
      SAIF_LLM_MODEL=@@LLM_MODEL@@
      SAIF_LLM_KEY=@@LLM_KEY@@
      SAIF_HOSTNAME=@@HOSTNAME@@
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
      # Refresh the course from the fork's Pages tarball, then apply the lab overlay: model calls
      # to this VM's /v1 (router + local embeddings) and RAG vectors re-embedded with the lab model.
      set -euo pipefail
      . /etc/saif/lab.env
      tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
      curl -fsSL --retry 5 "$SAIF_SITE_TARBALL" -o "$tmp/site.tgz"
      mkdir -p "$tmp/site" && tar -xzf "$tmp/site.tgz" -C "$tmp/site"
      python3 -I /opt/saif/apply_brand.py "$tmp/site" --only-llm --config /opt/saif/lab/brand-lab.json --base-url "https://$SAIF_HOSTNAME/v1"
      python3 -I /opt/saif/lab/rebuild_rag_index.py "$tmp/site" bge-small-en-v1.5 http://127.0.0.1:8081/v1
      sudo rm -rf /var/lib/saif-course/site.new && sudo mv "$tmp/site" /var/lib/saif-course/site.new
      sudo chmod -R a+rX /var/lib/saif-course/site.new
      sudo rm -rf /var/lib/saif-course/site && sudo mv /var/lib/saif-course/site.new /var/lib/saif-course/site
      echo "course updated from $SAIF_SITE_TARBALL (lab overlay applied)"
  - path: /opt/saif/apply_brand.py
    permissions: "0755"
    content: |
@@FILE:../apply_brand.py@@
  - path: /opt/saif/brand.json
    content: |
@@FILE:../brand.json@@
  - path: /opt/saif/lab/brand-lab.json
    content: |
@@FILE:brand-lab.json@@
  - path: /opt/saif/lab/rebuild_rag_index.py
    permissions: "0755"
    content: |
@@FILE:rebuild_rag_index.py@@
  - path: /usr/local/bin/saif-recover
    permissions: "0755"
    content: |
@@FILE:saif-recover@@
  - path: /usr/local/bin/saif-wait-model
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # Block until the lab router answers a chat turn with SAIF_LLM_MODEL (NemoClaw onboarding verifies it).
      . /etc/saif/lab.env
      for i in $(seq 1 ${1:-120}); do
        code=$(curl -s -m 60 -o /dev/null -w '%{http_code}' "$SAIF_LLM_URL/chat/completions" -H "Authorization: Bearer $SAIF_LLM_KEY" \
          -H 'Content-Type: application/json' -d "{\"model\":\"$SAIF_LLM_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":5}")
        [ "$code" = 200 ] && { echo "model $SAIF_LLM_MODEL ready"; exit 0; }
        echo "waiting for $SAIF_LLM_MODEL at $SAIF_LLM_URL (HTTP $code)"; sleep 30
      done
      exit 1
  - path: /etc/systemd/system/saif-nemoclaw-recover.service
    content: |
      [Unit]
      Description=SAIF: NemoClaw documented post-reboot recovery (status/start/probe/recover)
      After=network-online.target docker.service
      Wants=network-online.target docker.service
      [Service]
      Type=oneshot
      User=labadmin
      ExecStart=/usr/local/bin/saif-recover
      TimeoutStartSec=1500
      # recover starts the host dashboard forward as a child; keep it alive after the script exits
      # (a plain oneshot gets its leftover processes killed when it finishes).
      RemainAfterExit=yes
      KillMode=process
      [Install]
      WantedBy=multi-user.target
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
  # Local embeddings for the browser lessons (router has none). Small model + hard memory cap:
  # TEI's defaults with Qwen3-Embedding-0.6B OOM-killed the VM during warm-up.
  - [docker, run, -d, --name, saif-embed, --restart, unless-stopped, --memory, 1500m, --memory-swap, 1500m, --cpus, "2", -p, "127.0.0.1:8081:80", -v, "/var/lib/saif-embed:/data", "ghcr.io/huggingface/text-embeddings-inference:cpu-1.8", --model-id, BAAI/bge-small-en-v1.5]
  - [sh, -c, "for i in $(seq 1 60); do curl -sf 127.0.0.1:8081/health && break; sleep 5; done; su - labadmin -c saif-update-course || true"]
  - [rm, -f, /etc/nginx/sites-enabled/default]
  - [ln, -sf, /etc/nginx/sites-available/saif, /etc/nginx/sites-enabled/saif]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, qemu-guest-agent, docker, saif-agent-shim]
  - [systemctl, enable, saif-nemoclaw-recover]
  - [systemctl, reload, nginx]
  # NemoClaw + OpenClaw, unattended: the lab router key is the non-secret placeholder in lab.env.
  # Onboarding verifies a model call, so wait for the model first (up to ~60 min), then install in tmux.
  # Backgrounded so cloud-init (and create-vm.sh's HTTPS step) does not wait on the model.
  - [sh, -c, "nohup su - labadmin -c 'saif-wait-model 120 && saif-install-nemoclaw </dev/null' >> /var/log/saif-nemoclaw-autoinstall.log 2>&1 &"]
