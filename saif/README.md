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
