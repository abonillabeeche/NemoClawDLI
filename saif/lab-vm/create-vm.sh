#!/usr/bin/env bash
# Create the SAIF NemoClaw lab VM on a Harvester cluster (default: far-edge).
# Everything is overridable via env. Fully unattended: cloud-init installs nginx, the agent shim, local
# embeddings and the lab course overlay, then NemoClaw/OpenClaw once the router model answers; this
# script then deploys HTTPS (lab wildcard cert from ~/.acme.sh, required for lessons 3-4 in a browser).
# Prereqs: DNS A record $HOSTNAME -> $IP and a Calix reservation $IP <-> $MAC.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${KUBECONFIG_FILE:=$HOME/claude/virt/far-edge.yaml}"
: "${NS:=saif}" "${NAME:=saif-nemoclaw}"
: "${IP:=10.0.0.164}" "${PREFIX:=24}" "${GATEWAY:=10.0.0.1}" "${DNS:=10.0.0.1}"
: "${MAC:=52:54:00:5a:1f:62}" "${NET:=default/vlan1}"
: "${CPU:=4}" "${MEM:=12Gi}" "${MEM_REQ:=8Gi}" "${DISK:=60Gi}"
: "${IMAGE:=kasm-autoscale/ubuntu-noble}"
: "${SSH_PUBKEY_FILE:=$HOME/.ssh/id_rsa.pub}"
: "${LLM_URL:=http://10.0.0.10:30803/v1}" "${LLM_MODEL:=glm-5.3-flash}"
: "${LLM_KEY:=<router-key>}"            # lab router master placeholder (not a secret)
: "${HOSTNAME_FQDN:=saif-lab.5glinux.com}"
: "${SANDBOX:=saif-agent}"
: "${NEMOCLAW_REF:=525beba5024665def76bd69e81fad4d2b69e7cf6}"
: "${SITE_TARBALL:=https://abonillabeeche.github.io/NemoClawDLI/saif-site.tar.gz}"
k() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

IMG_NS=${IMAGE%%/*}; IMG_NAME=${IMAGE##*/}
SC=$(k get virtualmachineimage -n "$IMG_NS" "$IMG_NAME" -o jsonpath='{.status.storageClassName}')
[ -n "$SC" ] || { echo "image $IMAGE has no storage class" >&2; exit 1; }
k get vm -n "$NS" "$NAME" >/dev/null 2>&1 && { echo "VM $NS/$NAME already exists" >&2; exit 1; }
k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null

# Course basic-auth: user "saif", random password kept only in a cluster Secret.
if ! k get secret -n "$NS" saif-course-auth >/dev/null 2>&1; then
  k create secret generic -n "$NS" saif-course-auth --from-literal=username=saif \
    --from-literal=password="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)" >/dev/null
  echo "created secret $NS/saif-course-auth (course login user: saif)"
fi
HTPASSWD=$(k get secret -n "$NS" saif-course-auth -o jsonpath='{.data.password}' | base64 -d | htpasswd -niB saif)

ROUTER_URL=${LLM_URL%/}
ROUTER_HOSTPORT=$(printf '%s' "$ROUTER_URL" | sed -E 's#^[a-z]+://([^/]+).*#\1#')
USERDATA=$(HERE="$HERE" NAME="$NAME" LLM_KEY="$LLM_KEY" HOSTNAME="$HOSTNAME_FQDN" ROUTER_URL="$ROUTER_URL" ROUTER_HOSTPORT="$ROUTER_HOSTPORT" SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")" LLM_URL="$LLM_URL" LLM_MODEL="$LLM_MODEL" \
  SANDBOX="$SANDBOX" NEMOCLAW_REF="$NEMOCLAW_REF" SITE_TARBALL="$SITE_TARBALL" HTPASSWD="$HTPASSWD" \
  python3 -I - <<'PY'
import os, re, pathlib
here = pathlib.Path(os.environ["HERE"])
t = (here / "cloud-init.yaml.tpl").read_text()
t = re.sub(r"^@@FILE:(.+?)@@$", lambda m: "\n".join("      " + l if l else "" for l in (here / m.group(1)).read_text().splitlines()), t, flags=re.M)
for k in ["NAME", "SSH_PUBKEY", "LLM_URL", "LLM_MODEL", "LLM_KEY", "HOSTNAME", "ROUTER_URL", "ROUTER_HOSTPORT",
          "SANDBOX", "NEMOCLAW_REF", "SITE_TARBALL", "HTPASSWD"]:
    t = t.replace("@@%s@@" % k, os.environ[k])
assert "@@" not in t, "unfilled placeholder"
print(t)
PY
)
NETDATA=$(cat <<NET
version: 2
ethernets:
  lan:
    match: {macaddress: "$MAC"}
    set-name: eth0
    addresses: [$IP/$PREFIX]
    routes: [{to: default, via: $GATEWAY}]
    nameservers: {addresses: [$DNS], search: [5glinux.com]}
NET
)
k create secret generic -n "$NS" "$NAME-cloudinit" --from-literal=userdata="$USERDATA" \
  --from-literal=networkdata="$NETDATA" --dry-run=client -o yaml | k apply -f - >/dev/null

k apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NAME-root
  namespace: $NS
  annotations: {harvesterhci.io/imageId: $IMAGE}
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Block
  storageClassName: $SC
  resources: {requests: {storage: $DISK}}
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: $NAME
  namespace: $NS
  labels: {app: saif-nemoclaw}
spec:
  runStrategy: RerunOnFailure
  template:
    metadata:
      labels: {harvesterhci.io/vmName: $NAME}
    spec:
      domain:
        cpu: {cores: $CPU, sockets: 1, threads: 1}
        memory: {guest: $MEM}
        resources:
          limits: {cpu: "$CPU", memory: $MEM}
          requests: {cpu: "1", memory: $MEM_REQ}
        machine: {type: q35}
        features: {acpi: {enabled: true}}
        devices:
          disks:
            - {name: rootdisk, bootOrder: 1, disk: {bus: virtio}}
            - {name: cloudinitdisk, disk: {bus: virtio}}
          interfaces:
            - {name: lan, model: virtio, bridge: {}, macAddress: "$MAC"}
      networks:
        - {name: lan, multus: {networkName: $NET}}
      volumes:
        - {name: rootdisk, persistentVolumeClaim: {claimName: $NAME-root}}
        - name: cloudinitdisk
          cloudInitNoCloud:
            secretRef: {name: $NAME-cloudinit}
            networkDataSecretRef: {name: $NAME-cloudinit}
YAML
echo "VM $NS/$NAME starting at $IP (MAC $MAC)."

# --- post-boot automation -------------------------------------------------------------------------
dig +short "$HOSTNAME_FQDN" | grep -qx "$IP" || echo "WARNING: $HOSTNAME_FQDN does not resolve to $IP (add the DNS A record)"
ssh-keygen -R "$IP" >/dev/null 2>&1 || true            # a reused IP keeps an old host key
SSHO=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
echo "waiting for SSH and cloud-init on $IP ..."
for i in $(seq 1 90); do ssh "${SSHO[@]}" "labadmin@$IP" true 2>/dev/null && break; sleep 10; done
ssh "${SSHO[@]}" "labadmin@$IP" 'cloud-init status --wait >/dev/null; cloud-init status --long | grep -E "^(status|errors)"'
CERT_DIR="${CERT_DIR:-$HOME/.acme.sh/*.5glinux.com_ecc}"
if [ -r "$CERT_DIR/fullchain.cer" ]; then
  CERT_DIR="$CERT_DIR" "$HERE/deploy-tls.sh" "labadmin@$IP"
else
  echo "WARNING: no wildcard cert at $CERT_DIR; run deploy-tls.sh later (lessons 3-4 need HTTPS)"
fi
echo
echo "Course:   https://$HOSTNAME_FQDN/nemoclaw/   (user saif; password: secret $NS/saif-course-auth)"
echo "NemoClaw: installs automatically once $LLM_MODEL answers; follow with"
echo "          ssh labadmin@$IP 'tail -f /var/log/saif-nemoclaw-autoinstall.log ~/nemoclaw-install.log'"
