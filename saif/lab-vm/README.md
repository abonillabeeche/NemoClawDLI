# SAIF NemoClaw lab VM (modules 3-4 without Brev)

The hosted course drives a Brev "launchable": NVIDIA's VM image with NemoClaw + OpenShell +
OpenClaw that also serves the course on the same origin and exposes three endpoints the lessons
call. Plain NemoClaw has none of those endpoints, so this VM adds them:

| Path | Brev launchable | Here |
|---|---|---|
| `/` (course) | `/dli/` | branded site from `saif-site.tar.gz` (published by `saif-pages`) |
| `GET /api/agent` | agent metadata, `agent.dashboardUrl#token=` | `agent_shim.py` -> `nemoclaw <sandbox> dashboard-url --quiet` |
| `WS /cli/gateway` | OpenClaw gateway | nginx -> `127.0.0.1:18789` (NemoClaw's loopback forward) |
| `WS /ws/terminal?cmd=` | PTY, whitespace-split argv (no shell) | `agent_shim.py` (same contract; `stdio=pipe` supported) |

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

## HTTPS is required for lessons 3-4 in a browser

The course signs its OpenClaw gateway login with WebCrypto Ed25519 (`_gateway_auth.js`), which
browsers expose only in secure contexts. Over `http://10.0.0.164` the gateway socket opens and the
gateway logs `closed before connect`. Use either:

- `ssh -N -L 8164:127.0.0.1:80 labadmin@10.0.0.164` and browse `http://localhost:8164` (localhost is secure), or
- HTTPS: `cli53 rrcreate 5glinux.com 'saif-lab 300 A 10.0.0.164'`, then `saif/lab-vm/deploy-tls.sh`
  (lab wildcard cert; rerun after renewals), browse `https://saif-lab.5glinux.com`.

## Lab overlay: browser lessons use the lab models (2026-11-06)

`saif-update-course` applies `brand-lab.json` (`apply_brand.py --only-llm`) to the downloaded public
site and re-embeds every `rag_index.json` (`rebuild_rag_index.py`). Result on the VM only:

- default chat/embedding endpoint `https://saif-lab.5glinux.com/v1` (same origin; nginx `/v1/` ->
  router with `Bearer <router-key>`, `/v1/embeddings` -> TEI); any text works as the key
- models: `nvidia/nemotron-3.5-lightning-30b-a3b` and the omni model -> `glm-5.3-flash` (no vision;
  GLM cannot disable thinking, so "direct" and "reasoning" maze modes both reason);
  `nvidia/nemotron-3-embed-1b` -> `bge-small-en-v1.5` (384d; the course's embed model is not public)
- TEI container `saif-embed`: bge-small on CPU, capped at 1.5 GB (Qwen3-Embedding-0.6B OOM-killed
  the VM during warm-up even at 3 GB)

The GitHub Pages copy keeps upstream's NVIDIA defaults.

## Full-course E2E (2026-11-06, Playwright headless on the VM, lab overlay, GLM-5.3-Flash)

Every runnable cell passed at least once: 1a 15/15, 1b 6/6, 1c 26/26, 2a 21/21, 2b 21/21, 2c 16/16,
3a 17/17 (connection audit: metadata, gateway, terminal, health), 3b 13/13, 3c 11/11, 4a 14/14,
4b 4/4, glossary 6/6; Course Assistant answers; home/studio/localization/courses/dependencies/4c
load with no console or HTTP errors. Fixes it took (all in this kit): `reasoning_effort: "low"`
wherever the course disables thinking (GLM ignores `enable_thinking: false`), larger token caps
(01a direct maze, 02c workers), OpenClaw turn deadlines 240 s idle / 600 s total, and shim pipe
mode without stdin. Expect slow agent turns (GLM at default effort) and errors for router models
that are not loaded in the 3a latency benchmark.
