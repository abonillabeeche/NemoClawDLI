# SAIF edition

Branch `saif` = upstream NVDLI/NemoClawDLI + this directory + `.github/workflows/saif-pages.yml`.
Nothing else in the tree differs from `main`, so syncing upstream never conflicts.

- `brand.json`: name, palette (NVIDIA green -> SUSE Jungle/Mint), text swaps, stripped `ncid`
  referral params, Apache-2.0 attribution footer. Each rule has a `min` hit count; the build
  fails if upstream drifts below it.
- `apply_brand.py`: applies `brand.json` to a **built** site directory (never to source).
- Deploy: push to `saif` -> `saif-pages` workflow builds `main`, brands it, deploys to Pages.

Sync upstream:

```bash
gh repo sync abonillabeeche/NemoClawDLI           # main <- NVDLI main
git switch saif && git pull origin main --no-rebase && git push   # redeploys
```

Local preview (no build toolchain needed):

```bash
rm -rf /tmp/saif-preview && cp -R web /tmp/saif-preview
python3 -I saif/apply_brand.py /tmp/saif-preview
python3 -m http.server -d /tmp/saif-preview 8765   # open /nemoclaw/index.html
```

The course still uses NVIDIA endpoints by default; any OpenAI-compatible HTTPS endpoint
with CORS can be set per route in the key panel.

## Lab model router (`llm` in brand.json)

Empty `llm.base_url` = upstream NVIDIA defaults. Set it (HTTPS only) to make the lab LiteLLM
router the default chat + embedding route: swaps the default endpoint constant, drops the
`nvapi-` key checks, disables the NVIDIA DLI iframe relay, and rewrites the model/key copy.

Router requirements: HTTPS, CORS, and `Access-Control-Allow-Private-Network: true` on
preflight (the page is public, the router is private). Expose the models under the course ids
(`nvidia/nemotron-3.5-lightning-30b-a3b`, `nvidia/nemotron-3-embed-1b`) so lesson text and the
precomputed RAG vectors stay valid; otherwise fill `model_map` and rerun
`scripts/materials/build_rag_index.py`.
