#!/usr/bin/env python3
"""Re-embed every rag_index.json in a built site with the lab embedding model.

Keeps the upstream docs/queries texts (so corpus_hash still matches the #rag-cell corpus) and
replaces model/dim/vectors. Usage: rebuild_rag_index.py SITE_DIR MODEL [EMBED_URL]
"""
import json, sys, urllib.request
from datetime import date
from pathlib import Path

site, model = Path(sys.argv[1]), sys.argv[2]
url = (sys.argv[3] if len(sys.argv) > 3 else "http://127.0.0.1:8081/v1").rstrip("/") + "/embeddings"


def embed(texts):
    req = urllib.request.Request(url, json.dumps({"model": model, "input": texts}).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return [[round(x, 6) for x in row["embedding"]] for row in json.load(r)["data"]]


files = sorted(site.rglob("rag_index.json"))
if not files:
    sys.exit("no rag_index.json found under " + str(site))
cache = {}
for f in files:
    m = json.loads(f.read_text())
    for key in ("docs", "queries"):
        texts = [d["text"] for d in m.get(key, [])]
        missing = [t for t in texts if t not in cache]
        if missing:
            cache.update(zip(missing, embed(missing)))
        m[key] = [{"text": t, "vec": cache[t]} for t in texts]
    m["model"], m["generated"] = model, date.today().isoformat()
    m["dim"] = len(m["docs"][0]["vec"]) if m.get("docs") else m.get("dim")
    f.write_text(json.dumps(m, separators=(",", ":")))
    print(f"re-embedded {f.relative_to(site)}: {len(m.get('docs', []))} docs, {len(m.get('queries', []))} queries, dim {m['dim']}")
