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
saif/lab-vm/create-vm.sh                      # far-edge, 10.0.0.162, 4 vCPU / 12Gi (+8G swap) / 60Gi
# reserve the IP for the MAC on the Calix, then:
ssh labadmin@10.0.0.162 cloud-init status --wait
ssh -t labadmin@10.0.0.162 saif-install-nemoclaw     # prompts for the model-router key (stdin only)
ssh labadmin@10.0.0.162 saif-install-nemoclaw --status
```

Open `http://10.0.0.162/nemoclaw/03a-kickstart.html`, set the launchable URL to `http://10.0.0.162`,
and connect. Router/model live in `/etc/saif/lab.env` (`SAIF_LLM_URL`, `SAIF_LLM_MODEL`); change them
with `nemoclaw saif-agent inference set ...` after install. `saif-update-course` refreshes the site.

NemoClaw is pinned to a reviewed main commit (`NEMOCLAW_REF`); the `v1.0.0-rc1` tag does not
contain the installer. NemoClaw does not auto-recover after a VM reboot; follow its headless
"recover after a host reboot" sequence.
