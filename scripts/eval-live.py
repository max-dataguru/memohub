#!/usr/bin/env python3
"""Personal search eval on the live databases (0.6): full-text vs hybrid search.

    eval-live.py [questions.json]      default ~/.memohub/eval/questions.json

Questions stay outside the repository (they are about the owner's life):
    [{"t": "shared"|"private", "q": "question", "id": "<expected note id>", "kind": "keyword"|"meaning"}]
Query embeddings come from Ollama (MEMOHUB_OLLAMA_URL or ~/.memohub/ollama.url, model
embeddinggemma-2:270m, the same as memohub-index-embeddings.sh); one SQL call per database runs
both searches for every question. Prints hit@1, hit@5 and MRR per mode and kind, and each question
where the two modes differ. Read-only.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.environ.get("MEMOHUB_EMBEDDING_MODEL", "embeddinggemma-2:270m")


def embed(texts):
    url = os.environ.get("MEMOHUB_OLLAMA_URL") or open(os.path.expanduser("~/.memohub/ollama.url")).read().strip()
    req = urllib.request.Request(url.rstrip("/") + "/api/embed", data=json.dumps({"model": MODEL, "input": texts}).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)["embeddings"]


def run_sql(target, sql):
    wd = REPO if target == "shared" else os.path.join(REPO, "targets", "private")
    fd, path = tempfile.mkstemp(suffix=".sql")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(sql)
    try:
        out = subprocess.run(["supabase", "--workdir", wd, "db", "query", "--linked", "--output-format", "json", "-f", path],
                             capture_output=True, text=True, timeout=600)
    finally:
        os.unlink(path)
    if out.returncode != 0:
        raise RuntimeError(out.stderr[-300:])
    data = json.loads(out.stdout[re.search(r"^[\[{]", out.stdout, re.M).start():])
    rows = data["rows"] if isinstance(data, dict) else data
    v = list(rows[0].values())[0]
    return json.loads(v) if isinstance(v, str) else v


def lit(s):
    return "'" + s.replace("'", "''") + "'"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.memohub/eval/questions.json")
    qs = json.load(open(path, encoding="utf-8"))
    vecs = embed([q["q"] for q in qs])
    ranks = {}
    for t in sorted({q["t"] for q in qs}):
        rows = ",\n".join("(%d, %s, %s::extensions.vector)" % (i, lit(q["q"]), lit(json.dumps(vecs[i])))
                          for i, q in enumerate(qs) if q["t"] == t)
        sql = """select jsonb_agg(jsonb_build_object('i', v.i,
  'ft', (select coalesce(jsonb_agg(x->>'id'), '[]') from jsonb_array_elements(memohub.search(v.q, p_limit => 10)->'items') x),
  'hy', (select coalesce(jsonb_agg(x->>'id'), '[]') from jsonb_array_elements(
          memohub.search(v.q, null, null, null, 10, false, v.e, %s)->'items') x))) as r
from (values %s) v(i, q, e)""" % (lit(MODEL), rows)
        for r in run_sql(t, sql):
            q = qs[r["i"]]
            ranks[r["i"]] = {m: (r[m].index(q["id"]) + 1 if q["id"] in r[m] else None) for m in ("ft", "hy")}

    def stats(idx, m):
        rs = [ranks[i][m] for i in idx]
        n = len(rs) or 1
        return (sum(1 for x in rs if x == 1) / n, sum(1 for x in rs if x and x <= 5) / n,
                sum(1.0 / x for x in rs if x) / n)

    print("| Set | Questions | Full-text: top-1 / top-5 / MRR | Hybrid: top-1 / top-5 / MRR |")
    print("|---|---|---|---|")
    groups = [("all", list(range(len(qs))))] + [(k, [i for i, q in enumerate(qs) if q["kind"] == k])
                                                 for k in ("keyword", "meaning")]
    for name, idx in groups:
        f, h = stats(idx, "ft"), stats(idx, "hy")
        print("| %s | %d | %.2f / %.2f / %.2f | %.2f / %.2f / %.2f |" % ((name, len(idx)) + f + h))
    print()
    print("Where the modes differ (rank; — not in the top 10):")
    for i, q in enumerate(qs):
        a, b = ranks[i]["ft"], ranks[i]["hy"]
        if a != b:
            print("- %s [%s]: full-text %s, hybrid %s" % (q["q"], q["kind"], a or "—", b or "—"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
