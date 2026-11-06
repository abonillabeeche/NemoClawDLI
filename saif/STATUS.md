# SAIF edition: status, findings, TODO (2026-11-06)

Fork `abonillabeeche/NemoClawDLI`, branch `saif`. `main` mirrors upstream NVDLI/NemoClawDLI; only
`saif/` and `.github/workflows/saif-pages.yml` differ, so upstream merges stay conflict-free.

## What exists

| Piece | Where | State |
|---|---|---|
| Branded public site | https://abonillabeeche.github.io/NemoClawDLI/ (saif-pages workflow builds `main`, applies `saif/brand.json`) | live; NVIDIA model defaults by design |
| Lab course + agent host | https://saif-lab.5glinux.com (VM `saif/saif-nemoclaw` on far-edge, 10.0.0.164) | live; lab models; basic auth user `saif` (secret `saif/saif-course-auth`) |
| VM kit | `saif/lab-vm/` (`create-vm.sh`, cloud-init, `agent_shim.py`, nginx, `deploy-tls.sh`, `saif-recover`, lab overlay) | fully unattended, proven on a fresh build |

## Done and verified

- **Fresh build, no manual steps** (2026-11-06): `create-vm.sh` → cloud-init clean → HTTPS deployed →
  NemoClaw auto-installed once the model answered → 3a connection audit passes (metadata, gateway,
  terminal, health) → smoke test 1b 6/6, 2b 21/21, 4b 4/4.
- **Full course E2E** (previous VM, same kit): every runnable cell passed at least once: 1a 15/15,
  1b 6/6, 1c 26/26, 2a 21/21, 2b 21/21, 2c 16/16, 3a 17/17, 3b 13/13, 3c 11/11, 4a 14/14, 4b 4/4,
  glossary 6/6; Course Assistant answers; other pages load without console/HTTP errors.
- **Reboot recovery**: 3 reboots; healthy ~2 min after boot (`saif-nemoclaw-recover.service`).
- Model stack: chat `glm-5.3-flash` via LiteLLM (`http://10.0.0.10:30803/v1`; key: see local `~/claude/saif-lab/ACCESS.md`),
  embeddings `bge-small-en-v1.5` in TEI on the VM, all reached same-origin through nginx `/v1`.

## Findings (why the kit looks the way it does)

1. **Brev-only endpoints.** Lessons 3-4 call `/api/agent`, `/cli/gateway`, `/ws/terminal` from NVIDIA's
   Brev launchable image; NemoClaw/OpenClaw do not provide them. `agent_shim.py` + nginx implement the
   current contract: `/api/agent` returns the `/api/agent/launch` handoff (not a token URL; OpenClaw
   2026.9 rejects token-only Control UI logins), `/ws/terminal` splits commands on whitespace with no
   shell (the course probes this), and `stdio=pipe` gets no stdin (else `openshell sandbox exec` hangs).
2. **HTTPS is mandatory** for lessons 3-4: the course signs the gateway login with WebCrypto Ed25519,
   which browsers only allow in secure contexts.
3. **GLM ignores `enable_thinking: false`.** Only `reasoning_effort: "low"` disables its reasoning
   (82 vs 300+ tokens, 4 s vs 12 s). The lab overlay adds it wherever the course turns thinking off and
   raises small token caps (01a maze, 02c workers) and OpenClaw turn deadlines (240 s idle / 600 s).
4. **Embeddings:** the course's `nvidia/nemotron-3-embed-1b` is not public; the router has no embedding
   model. Qwen3-Embedding-0.6B OOM-killed the VM even capped at 3 GB; bge-small (1.2 GB) works. RAG
   manifests are re-embedded on every course refresh (`rebuild_rag_index.py`).
5. **Vision:** `glm-5.3-flash` does image + tool call in one turn (5/5), so the 01a "omni" mode maps to
   it. `qwen2.5-vl-7b` (`vllm-qwen-vl`, agx-orin-2 :30801) reads images (5/5) but has no LiteLLM route
   and no tool-calling flags.
6. **NemoClaw install gotchas:** needs `binutils`, `umask 022` (nvm prefix), and
   `NEMOCLAW_TRUSTED_PRIVATE_HOSTS` for an RFC1918 router; the `v1.0.0-rc1` tag has no installer
   (pinned to main `525beba`).
7. **Reboot:** OpenClaw holds a 5-minute `gateway-lifecycle` lease after an unclean stop and refuses to
   start until it expires; `recover` alone fails. `saif-recover` retries gateway restart + recover; the
   unit needs `RemainAfterExit=yes` / `KillMode=process` or systemd kills the forward `recover` starts.
8. **Router auth:** only the router's configured key works (others: `No connected db`); nginx injects it.
   Credentials and access are documented locally in `~/claude/saif-lab/ACCESS.md`, never in this repo.
9. **Test from the VM, not the Mac:** the Mac over Tailscale had 20% loss; Spark is a Tailscale exit node
   with constant network churn (`ERR_NETWORK_CHANGED`). Playwright harness lives in `~/saif-e2e` on the
   VM (not part of the kit; reinstall after a rebuild).

## Known limitations

- Agent turns (3b/3c/4a) are slow: the OpenClaw agent runs GLM at default (high) effort.
- 3a latency benchmark lists router models that are not loaded; those rows error.
- GLM always reasons unless `reasoning_effort: low` is sent; "direct" vs "reasoning" contrasts in 01a
  are now low-effort vs full reasoning rather than NVIDIA's thinking toggle.
- The lab site works only on the lab LAN / Tailscale (private IP behind a public DNS name).
- Wildcard cert renewal is not pushed automatically: rerun `saif/lab-vm/deploy-tls.sh` (next 2026-12-24).

## TODO

- [ ] Faster agent turns: LiteLLM route (e.g. `glm-5.3-flash-low`) defaulting to `reasoning_effort: low`
      and point the agent at it (`nemoclaw inference set --model ... --sandbox saif-agent`).
- [ ] Optional VLM: add `--enable-auto-tool-choice --tool-call-parser hermes` to `vllm-qwen-vl`, add a
      LiteLLM route, and map the omni model to it; clean the 14 stale `UnexpectedAdmissionError` pods
      in ns `vllm`.
- [ ] Rerun the full-course E2E on the fresh VM (only the smoke test ran after the rebuild).
- [ ] Health check (cron/monitor) for `/api/agent` + gateway forward between reboots.
- [ ] Prune paired test devices on the gateway (`openclaw devices list` inside the sandbox).
- [ ] Add `saif-lab` to the wildcard-cert deploy runbook.
- [ ] Decide whether the public GitHub Pages copy should stay on NVIDIA defaults or point elsewhere.
- [ ] Disable upstream workflows in the fork after the first `main` sync (`gh workflow disable`).
- [ ] Revisit the NemoClaw pin when an upstream release tag contains the installer.
