#!/usr/bin/env python3
"""Offline evaluation of the nightly distiller (scripts/distill.py) on chosen journal chats.

Nothing is written to the databases. It uses the distiller's own prompt, input and validation,
so a change there is measured here. Chats are read from the journal (memohub.captures) with the
linked supabase CLI, sent to headless Claude Code (--model claude:sonnet) or a local Ollama model,
and the proposals are written to a report in ~/.memohub/distill-eval/<run>/ for a person to
review. The terminal shows counts only.

  distill-eval.py pick [--n 20]     choose chats: those with notes saved from them, then others
  distill-eval.py run [--model M]   run the model on the chosen chats, write report.md
  distill-eval.py score <run>       read the verdicts filled in labels.csv, print totals

Chats with a note saved from the same chat (same chat_ref) give a reference: the report shows the
note next to the proposals, and an embedding similarity tells whether the note was found.
Config: --target private|shared (default private, where the journal is), OLLAMA_URL (default
from ~/.memohub/ollama.url, else http://localhost:11434), DISTILL_EMBED_MODEL.
"""
import argparse
import csv
import hashlib
import datetime
import json
import math
import os
import random
import re
import subprocess
import sys
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~/.memohub")
OUT = os.path.join(HOME, "distill-eval")
WORKDIR = {"shared": REPO, "private": os.path.join(REPO, "targets", "private")}

MATCH = 0.80              # cosine above which a proposal counts as finding the reference note


def _load_distill():
    """The nightly distiller's prompt, schema, input and model call, so the eval measures it."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("distill", os.path.join(REPO, "scripts", "distill.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


D = _load_distill()


def model_conf(model, target):
    """A distill.conf for this run: bare names are Ollama models."""
    model = model if re.match(r"^(claude|ollama):", model) else "ollama:" + model
    return {"TARGET": target, "MODEL": model, "MAX_CHARS": D.default_max_chars(model)}


def ollama_url():
    url = os.environ.get("OLLAMA_URL")
    if not url and os.path.exists(os.path.join(HOME, "ollama.url")):
        url = open(os.path.join(HOME, "ollama.url")).read().strip()
    return (url or "http://localhost:11434").rstrip("/")


def post(path, body, timeout=900):
    req = urllib.request.Request(ollama_url() + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def query(target, sql):
    """Run a read-only query through the linked supabase CLI and return rows (3 tries)."""
    for attempt in range(3):
        out = subprocess.run(["supabase", "--workdir", WORKDIR[target], "db", "query", "--linked",
                              "--output-format", "json", sql], capture_output=True, text=True, timeout=300)
        m = re.search(r"^[\[{]", out.stdout, re.M) if out.returncode == 0 else None
        if m:
            break
        if attempt == 2:
            err = [l for l in out.stderr.splitlines() if "Initialising login role" not in l]
            raise RuntimeError(("\n".join(err) or "supabase CLI failed").strip()[-300:])
        time.sleep(15 * (attempt + 1))
    data = json.loads(out.stdout[m.start():])
    return data["rows"] if isinstance(data, dict) else data


def lit(s):
    if not re.fullmatch(r"[A-Za-z0-9_.:@-]{1,200}", s):
        raise ValueError("unexpected chat_ref format")
    return "'" + s + "'"


def notes_for(refs):
    """Active notes saved from these chats, from both databases."""
    if not refs:
        return {}
    sql = ("select chat_ref, title, body_md, decisions from memohub.notes where status = 'active' "
           "and chat_ref in (%s)" % ",".join(lit(r) for r in refs))
    found = {}
    for t in ("shared", "private"):
        for row in query(t, sql):
            found.setdefault(row["chat_ref"], []).append(row)
    return found


def cmd_pick(a):
    os.makedirs(OUT, exist_ok=True)
    chats = query(a.target, "select chat_ref, source, coalesce(project_hint, '') as project, "
                            "count(*) as msgs, sum(least(length(content), %d)) as chars from memohub.captures "
                            "where source <> 'meeting' group by 1, 2, 3 having count(*) >= 6 "
                            "and max(event_at) < now() - interval '2 hours'" % D.MSG_CHARS)
    # The whole chat must fit what the run will send, so the model and the reference note see the
    # same text; the current session is still growing and is skipped.
    current = "cc-" + os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    limit = model_conf(a.model, a.target)["MAX_CHARS"]
    chats = [c for c in chats if c["chars"] <= limit * 0.9 and c["chat_ref"] != current]
    with_notes = notes_for([c["chat_ref"] for c in chats])
    pos = [c for c in chats if c["chat_ref"] in with_notes]
    rest = [c for c in chats if c["chat_ref"] not in with_notes]
    random.Random(a.seed).shuffle(rest)
    picked = (pos + rest)[:a.n]
    path = os.path.join(OUT, "chats.txt")
    with open(path, "w") as f:
        f.write("# chat_ref  source  project  messages  (edit freely; # lines are ignored)\n")
        for c in picked:
            f.write("%s  %s  %s  %s\n" % (c["chat_ref"], c["source"], c["project"] or "-", c["msgs"]))
    print("picked %d chats: %d with a saved note, %d without -> %s"
          % (len(picked), min(len(pos), a.n), len(picked) - min(len(pos), a.n), path))


def transcript(target, ref, titles=()):
    """Messages before the first save request or mention of a saved note's title: the part the
    reference note was made from, so the model cannot copy it."""
    rows = query(target, "select id, role, event_at, content from memohub.captures where chat_ref = %s "
                         "order by event_at, seq, part, id" % lit(ref))
    cut = None
    for n, r in enumerate(rows):
        low = r["content"].lower()
        why = ("save request" if (r["role"] == "user" and D.SAVE_REQUEST.search(r["content"]))
               or D.SAVED.search(r["content"]) else
               "saved title" if any(t[:40].lower() in low for t in titles) else None)
        if why:
            cut = "cut before message %d of %d (%s)" % (n + 1, len(rows), why)
            rows = rows[:n]
            break
    return rows, cut


def embed(texts):
    if not texts:
        return []
    model = os.environ.get("DISTILL_EMBED_MODEL", "embeddinggemma-2:270m")
    return post("/api/embed", {"model": model, "input": texts})["embeddings"]


def cos(a, b):
    return sum(x * y for x, y in zip(a, b)) / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)))


def note_text(n):
    return n["title"] + "\n" + "\n".join(n.get("decisions") or [])


def cmd_run(a):
    conf = model_conf(a.model, a.target)
    path = os.path.join(OUT, "chats.txt")
    chats = [l.split() for l in open(path) if l.strip() and not l.startswith("#")][:a.limit]
    run = datetime.datetime.now().strftime("%Y%m%d-%H%M") + "-" + conf["MODEL"].replace(":", "-")
    rdir = os.path.join(OUT, run)
    os.makedirs(rdir)
    refs = notes_for([c[0] for c in chats])
    catalog = D.load_catalog(conf)
    system = D.SYSTEM.format(max=D.MAX_NOTES)
    report = ["# Distillation eval %s" % run, "",
              "Model `%s`, the nightly distiller's prompt. Fill `labels.csv`: for each proposal good / "
              "partial / noise, and for each chat whether something should have been saved." % conf["MODEL"], ""]
    labels = [["chat_ref", "item", "title", "verdict"]]
    stats = {"chats": 0, "proposals": 0, "dropped": 0, "seconds": 0.0, "cost_usd": 0.0,
             "with_ref": 0, "ref_found": 0}
    for i, c in enumerate(chats, 1):
        ref, source, project = c[0], c[1], (None if c[2] == "-" else c[2])
        head = ["## %d. %s (%s, %s)" % (i, ref, source, project or "-"), ""]
        try:
            msgs, cut = transcript(a.target, ref, [n["title"] for n in refs.get(ref, [])])
            pending = {"chat_ref": ref, "source": source, "project_hint": project}
            tail, size, user = D.build_input({"messages": msgs, "saved_titles": []}, pending, catalog,
                                             conf["MAX_CHARS"])
        except Exception as e:  # noqa: BLE001 - one bad chat must not stop the run
            print("%2d/%d  error: %s" % (i, len(chats), str(e)[:200]), flush=True)
            report += head + ["Error, skipped.", ""]
            continue
        # Finished chats are cached per model, prompt and input, so a rerun after a failure resumes.
        key = hashlib.sha256((conf["MODEL"] + system + user).encode()).hexdigest()[:16]
        cpath = os.path.join(OUT, "cache", key + ".json")
        if os.path.exists(cpath):
            cached = json.load(open(cpath))
            notes, spent, cost = cached["notes"], cached["seconds"], cached.get("cost", 0)
        elif size < D.MIN_TAIL_CHARS:
            notes, spent, cost = [], 0.0, 0.0
        else:
            t = time.time()
            try:
                notes, cost = D.ask(conf, system, user)
            except Exception as e:  # noqa: BLE001
                print("%2d/%d  error: %s" % (i, len(chats), str(e)[:200]), flush=True)
                report += head + ["Error, skipped.", ""]
                continue
            spent = time.time() - t
            os.makedirs(os.path.dirname(cpath), exist_ok=True)
            json.dump({"notes": notes, "seconds": spent, "cost": cost}, open(cpath, "w"), ensure_ascii=False)
        # The same validation as the nightly run: space, sources and the confidence floor.
        cands, dropped = D.to_candidates(notes, tail, catalog, project)
        props = [dict(c["payload"], confidence=c["confidence"]) for c in cands]
        stats["chats"] += 1
        stats["proposals"] += len(props)
        stats["dropped"] += dropped
        stats["seconds"] += spent
        stats["cost_usd"] += cost
        report += head + ["Messages: %d, sent %d characters.%s%s" % (
            len(msgs), size, " Transcript " + cut + "." if cut else "",
            " Dropped by validation: %d." % dropped if dropped else ""), ""]
        best = None
        if ref in refs:
            stats["with_ref"] += 1
            ev = embed([note_text(n) for n in refs[ref]] + [note_text(p) for p in props])
            k = len(refs[ref])
            if props:
                best = max(cos(ev[x], ev[y]) for x in range(k) for y in range(k, len(ev)))
                stats["ref_found"] += best >= MATCH
            report += ["### Saved note (reference)", ""]
            for n in refs[ref]:
                report += ["- **%s**" % n["title"]] + ["  - %s" % d for d in (n.get("decisions") or [])]
            report += ["", "Best similarity to a proposal: %s" % ("%.2f" % best if best is not None else "none"), ""]
        report += ["### Proposals", ""] if props else ["### Proposals", "", "None.", ""]
        for j, p in enumerate(props, 1):
            report += ["%d. **%s** (%s%s, confidence %.2f)" % (j, p["title"], p["space"],
                       " / " + p["project"] if p.get("project") else "", float(p.get("confidence") or 0)), "",
                       p.get("body_md", "").strip(), ""]
            report += ["   - decision: %s" % d for d in p.get("decisions") or []]
            report += ["   - open: %s" % q for q in p.get("open_questions") or []]
            report += [""]
            labels.append([ref, str(j), p["title"][:80], ""])
        labels.append([ref, "chat", "should something be saved? yes / no", ""])
        labels.append([ref, "overall", "would these replace your own note? good / partial / noise", ""])
        print("%2d/%d  proposals %d  %s%s" % (i, len(chats), len(props),
              "ref %.2f" % best if best is not None else ("ref none" if ref in refs else ""),
              "  cut" if cut else ""), flush=True)
    with open(os.path.join(rdir, "report.md"), "w") as f:
        f.write("\n".join(report) + "\n")
    with open(os.path.join(rdir, "labels.csv"), "w", newline="") as f:
        csv.writer(f).writerows(labels)
    stats["cost_usd"] = round(stats["cost_usd"], 2)
    with open(os.path.join(rdir, "stats.json"), "w") as f:
        json.dump(stats, f, indent=1)
    print("done: %d chats, %d proposals (%d dropped), %.0f s model time, $%.2f list price; "
          "reference notes found %d of %d" % (stats["chats"], stats["proposals"], stats["dropped"],
                                              stats["seconds"], stats["cost_usd"], stats["ref_found"],
                                              stats["with_ref"]))
    print("report: %s" % os.path.join(rdir, "report.md"))


def cmd_score(a):
    rows = list(csv.DictReader(open(os.path.join(OUT, a.run, "labels.csv"))))
    items = [r for r in rows if r["item"] not in ("chat", "overall")]
    overall = [r["verdict"].strip().lower() for r in rows if r["item"] == "overall"]
    v = [r["verdict"].strip().lower() for r in items]
    chat = {r["chat_ref"]: r["verdict"].strip().lower() for r in rows if r["item"] == "chat"}
    have = {r["chat_ref"] for r in items}
    print("proposals: %d good, %d partial, %d noise, %d unlabelled"
          % (v.count("good"), v.count("partial"), v.count("noise"), v.count("")))
    print("chats overall: %d good, %d partial, %d noise"
          % (overall.count("good"), overall.count("partial"), overall.count("noise")))
    want = [c for c, x in chat.items() if x == "yes"]
    print("chats that should give a note: %d, of them with a proposal: %d; chats that should not: %d, "
          "of them with a proposal: %d" % (len(want), sum(c in have for c in want),
                                          sum(x == "no" for x in chat.values()),
                                          sum(x == "no" and c in have for c, x in chat.items())))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--target", choices=WORKDIR, default="private")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("pick")
    s.add_argument("--n", type=int, default=20)
    s.add_argument("--model", default="claude:sonnet", help="sets how long a chat may be")
    s.add_argument("--seed", type=int, default=1)
    s = sub.add_parser("run")
    s.add_argument("--model", default="claude:sonnet",
                   help="claude:<model> (headless Claude Code) or an Ollama model (qwen3:8b, ollama:qwen3:8b)")
    s.add_argument("--limit", type=int, help="only the first N chats")
    s = sub.add_parser("score")
    s.add_argument("run")
    a = p.parse_args()
    {"pick": cmd_pick, "run": cmd_run, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
