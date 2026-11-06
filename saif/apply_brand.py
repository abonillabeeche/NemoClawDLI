#!/usr/bin/env python3
"""Apply SAIF branding to a built NemoClawDLI site directory.

Usage: python3 -I saif/apply_brand.py PUBLIC_DIR [--config saif/brand.json] [--dry-run]

Runs on build output only. Upstream source stays untouched on the saif branch, so
`main` (an upstream mirror) merges into `saif` without conflicts.
"""
import argparse
import json
import re
import sys
from pathlib import Path


def strip_params(text, params):
    hits = 0
    for p in params:
        # ?p=v&rest -> ?rest ; ?p=v -> "" ; &p=v / &amp;p=v -> ""
        pat = re.compile(r"([?&]|&amp;)" + re.escape(p) + r"=[^&\"'#\s<>)\\]*(&amp;|&)?")

        def repl(m):
            sep, trail = m.group(1), m.group(2)
            return "?" if sep == "?" and trail else ""

        text, n = pat.subn(repl, text)
        hits += n
    return text, hits


def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--config", default=str(here / "brand.json"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--only-llm", action="store_true", help="apply only the llm block (lab overlay on an already-branded site)")
    a = ap.parse_args()

    cfg = json.loads(Path(a.config).read_text())
    llm_cfg = cfg.get("llm", {})
    if "rules_from" in llm_cfg and "rules" not in llm_cfg:  # overlay reuses the main config's llm rules
        base = json.loads((Path(a.config).parent / llm_cfg["rules_from"]).read_text())
        llm_cfg["rules"] = base["llm"]["rules"]
    root = Path(a.root)
    if not (root / "nemoclaw" / "index.html").is_file() and not (root / "index.html").is_file():
        sys.exit(f"{root} does not look like a built site")

    rules = [] if a.only_llm else [("color", r) for r in cfg["colors"]] + [("text", r) for r in cfg["text"]]
    llm = cfg.get("llm", {})
    if llm.get("base_url"):
        base = llm["base_url"].rstrip("/")
        if not base.startswith("https://"):
            sys.exit("llm.base_url must be https:// (the site is served over HTTPS; browsers block mixed content)")
        subst = {"{base_url}": base, "{router_label}": llm.get("router_label", "lab model router"),
                 "{key_help_url}": llm.get("key_help_url", "")}
        for r in llm["rules"]:
            to = r["to"]
            for k, v in subst.items():
                to = to.replace(k, v)
            rules.append(("text", {**r, "to": to}))
        for old, new in llm.get("model_map", {}).items():
            rules.append(("text", {"from": '"%s"' % old, "to": '"%s"' % new, "min": 1}))
        print(f"llm: default endpoint -> {base}")
    else:
        print("llm: base_url empty, keeping upstream NVIDIA endpoint defaults")
    counts = {r["from"]: 0 for _, r in rules}
    params, attribution = cfg.get("strip_query_params", []), cfg.get("attribution_html", "")
    if a.only_llm:
        params, attribution = [], ""
    param_hits = footer_hits = files_changed = 0
    skip = set(cfg["skip_dirs"])

    for f in sorted(root.rglob("*")):
        if not f.is_file() or f.suffix.lower() not in cfg["extensions"]:
            continue
        if skip.intersection(f.relative_to(root).parts):
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        # Strip tracking params first so text rules always target clean URLs (single pass or overlay).
        new, n = strip_params(text, params)
        param_hits += n
        for kind, r in rules:
            if kind == "color":
                pat = re.compile(re.escape(r["from"]), re.IGNORECASE)
                new, n = pat.subn(r["to"], new)
            else:
                n = new.count(r["from"])
                new = new.replace(r["from"], r["to"])
            counts[r["from"]] += n
        if attribution and f.suffix == ".html" and "</footer>" in new and "saif-attribution" not in new:
            new = new.replace("</footer>", "  " + attribution + "\n  </footer>", 1)
            footer_hits += 1
        if new != text:
            files_changed += 1
            if not a.dry_run:
                f.write_text(new, encoding="utf-8")

    bad = []
    for _, r in rules:
        flag = "" if counts[r["from"]] >= r.get("min", 0) else "  <-- below min %d" % r["min"]
        if flag:
            bad.append(r["from"])
        print(f"{counts[r['from']]:6d}  {r['from']!r} -> {r['to']!r}{flag}")
    print(f"{param_hits:6d}  query params stripped {params}")
    print(f"{footer_hits:6d}  footers given attribution")
    print(f"{files_changed:6d}  files changed{' (dry run)' if a.dry_run else ''}")
    if bad:
        sys.exit(f"upstream drift: {len(bad)} rule(s) matched fewer times than expected; update saif/brand.json")


if __name__ == "__main__":
    main()
