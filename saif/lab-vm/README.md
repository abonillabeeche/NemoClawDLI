# SAIF NemoClaw lab VM (modules 3-4 without Brev)

The hosted course drives a Brev "launchable": NVIDIA's VM image with NemoClaw + OpenShell +
OpenClaw that also serves the course on the same origin and exposes three endpoints the lessons
call. Plain NemoClaw has none of those endpoints, so this VM adds them:

| Path | Brev launchable | Here |
|---|---|---|
| `/` (course) | `/dli/` | branded site from `saif-site.tar.gz` (published by `saif-pages`) |
| `GET /api/agent` | agent metadata, `agent.dashboardUrl#token=` | `agent_shim.py` -> `nemoclaw <sandbox> dashboard-url --quiet` |
| `WS /cli/gateway` | OpenClaw gateway | nginx -> `127.0.0.1:18789` (NemoClaw's loopback forward) |
| `WS /ws/terminal?cmd=` | PTY | `agent_shim.py` (`bash -lc` as labadmin; `stdio=pipe` supported) |

Access: nginx basic auth (user `saif`, password in Secret `saif/saif-course-auth`), lab LAN /
Tailscale only. `/ws/terminal` is a shell on the VM by design (same as the launchable).

## Use

```bash
saif/lab-vm/create-vm.sh                      # far-edge, 10.0.0.164, 4 vCPU / 12Gi (+8G swap) / 60Gi
# reserve the IP for the MAC on the Calix, then:
ssh labadmin@10.0.0.164 cloud-init status --wait
echo <router-key> | ssh labadmin@10.0.0.164 saif-install-nemoclaw   # lab router takes any bearer
ssh labadmin@10.0.0.164 saif-install-nemoclaw --status
```

Open `http://10.0.0.164/nemoclaw/03a-kickstart.html`, set the launchable URL to `http://10.0.0.164`,
and connect. Router/model live in `/etc/saif/lab.env` (`SAIF_LLM_URL`, `SAIF_LLM_MODEL`); change them
with `nemoclaw saif-agent inference set ...` after install. `saif-update-course` refreshes the site.

NemoClaw is pinned to a reviewed main commit (`NEMOCLAW_REF`); the `v1.0.0-rc1` tag does not
contain the installer. NemoClaw does not auto-recover after a VM reboot; follow its headless
"recover after a host reboot" sequence.

## Validated 2026-11-05 (far-edge, 10.0.0.164)

NemoClaw `525beba`, OpenShell 0.0.116, OpenClaw 2026.9.2, sandbox `saif-agent`, model `glm-5.3-flash`
via `http://10.0.0.10:30803/v1`. `/api/agent` returns the gateway token, `/cli/gateway` reaches the
OpenClaw `connect.challenge` through nginx, `/ws/terminal` runs `openshell sandbox list`, and an agent
turn answers. Gotchas fixed in this kit: binutils, umask 022 for nvm, `NEMOCLAW_TRUSTED_PRIVATE_HOSTS`
for the RFC1918 router, nginx HTTP/1.1 to the shim. Switch model:
`nemoclaw inference set --provider compatible-endpoint --model <id> --sandbox saif-agent`.
