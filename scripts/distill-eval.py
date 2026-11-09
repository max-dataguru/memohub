#!/usr/bin/env python3
"""Offline evaluation of distillation: a model proposes notes from journal chats.

Nothing is written to the databases. Chats are read from the journal (memohub.captures) with the
linked supabase CLI, sent to a local Ollama model or to headless Claude Code (--model
claude:sonnet), and the proposals are written to a report in
~/.memohub/distill-eval/<run>/ for a person to review. The terminal shows counts only.

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

WINDOW_CHARS = 60000      # about 20k tokens of mixed Russian and English text
MAX_WINDOWS = 4           # per chat; the newest windows are kept
MSG_CHARS = 4000          # long tool output and pasted files are cut
MAX_CANDIDATES = 3        # per window
SAVE_REQUEST = re.compile(r"(^|[\s/:])tomemo\b|запомни итог|remember the summary"
                          r"|(сохрани|запиши|добавь)\w*\b.{0,40}\b(memohub|мемохаб)"
                          r"|save\b.{0,30}\bmemohub", re.I | re.S)
SAVED = re.compile(r"memohub\.save|запись сохранена|сохранен\w* в (memohub|мемохаб)|saved (it )?to memohub",
                   re.I)
MAX_OUTPUT = 3000         # tokens per answer; three notes need well under this
MATCH = 0.80              # cosine above which a proposal counts as finding the reference note

SYSTEM = """You read a transcript of a chat between a user and an AI assistant and pick out what the user will want to remember months later:
- decisions, with the reason;
- agreements and plans, next steps;
- facts about the user's projects, tools and setup that are not obvious from the code.

Skip routine work: commands, debugging steps, file edits, test runs, anything that only mattered while the chat lasted. Most chats have nothing worth saving; then return an empty list.

One note per topic, with every decision on that topic in it; never split a topic across notes or repeat a point in two notes. A long chat comes in parts: with each part you get the notes proposed so far. Return the full updated list: keep what still holds, merge new points into the note on the same topic, replace what the user changed later, add a note only for a new topic. Most chats have one topic. At most {max} notes.

Each note:
- title: specific, under 120 characters;
- body_md: short markdown with the context and the outcome, in your own words. No quotes from the chat;
- decisions: each one understandable without the chat and ending with its reason ("..., because ..."). Decisions not to do something, or to wait, count too and are often the most useful;
- open_questions: what is still open, if anything;
- confidence: 0..1, how sure you are the user would keep this note.

Do not attribute words or positions to anyone unless the transcript says plainly who said them; text the user drafts or pastes for a reply is the user's. Do not add numbers, limits or rules that are not in the transcript.

Write in the language of the chat. Never include secrets, passwords, tokens, connection strings, card, account or document numbers, addresses or phone numbers; text like [masked:...] stays out of the note."""

SCHEMA = {
    "type": "object",
    "properties": {"notes": {"type": "array", "maxItems": MAX_CANDIDATES, "items": {
        "type": "object",
        "properties": {
            "title": {"type": "string"},
            "body_md": {"type": "string"},
            "decisions": {"type": "array", "items": {"type": "string"}},
            "open_questions": {"type": "array", "items": {"type": "string"}},
            "confidence": {"type": "number"},
        },
        "required": ["title", "body_md", "decisions", "confidence"],
    }}},
    "required": ["notes"],
}


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
                            "and max(event_at) < now() - interval '2 hours'" % MSG_CHARS)
    # The whole chat must fit the windows the run will read, so the model and the reference note
    # see the same text; the current session is still growing and is skipped.
    current = "cc-" + os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    chats = [c for c in chats if c["chars"] <= WINDOW_CHARS * MAX_WINDOWS * 0.95 and c["chat_ref"] != current]
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
    rows = query(target, "select role, content from memohub.captures where chat_ref = %s "
                         "order by event_at, seq, part" % lit(ref))
    # Stop before the first save request: a note saved from this chat must not leak into the input.
    cut = None
    for n, r in enumerate(rows):
        low = r["content"].lower()
        why = ("save request" if (r["role"] == "user" and SAVE_REQUEST.search(r["content"]))
               or SAVED.search(r["content"]) else
               "saved title" if any(t[:40].lower() in low for t in titles) else None)
        if why:
            cut = "cut before message %d of %d (%s)" % (n + 1, len(rows), why)
            rows = rows[:n]
            break
    lines = []
    for r in rows:
        text = r["content"]
        if len(text) > MSG_CHARS:
            text = text[:MSG_CHARS] + " [...cut]"
        lines.append("[%s] %s" % (r["role"], text))
    windows, cur = [], ""
    for line in lines:
        if cur and len(cur) + len(line) > WINDOW_CHARS:
            windows.append(cur)
            cur = ""
        cur += line + "\n\n"
    if cur:
        windows.append(cur)
    return windows[-MAX_WINDOWS:], len(windows), cut


def propose(model, meta, window, think, part, parts, so_far):
    user = "Source: %s. Project: %s. Part %d of %d%s.\n\nNotes so far:\n%s\n\n<transcript>\n%s</transcript>" % (
        meta[0], meta[1], part, parts, " (earlier parts were skipped)" if part == 1 and parts > 1 else "",
        json.dumps({"notes": so_far}, ensure_ascii=False) if so_far else "none", window)
    t = time.time()
    if model.startswith("claude:"):
        return propose_claude(model.split(":", 1)[1], user, so_far, t)
    r = post("/api/chat", {
        "model": model, "stream": False, "think": think, "format": SCHEMA,
        "options": {"num_ctx": 32768, "temperature": 0.2, "num_predict": MAX_OUTPUT + (6000 if think else 0),
                    "repeat_penalty": 1.1},
        "messages": [{"role": "system", "content": SYSTEM.format(max=MAX_CANDIDATES)},
                     {"role": "user", "content": user}],
    })
    if r.get("done_reason") == "length":  # the model looped; keep what was proposed before
        print("    window %d: answer cut, kept the previous notes" % part, flush=True)
        return so_far, time.time() - t, r.get("prompt_eval_count", 0), r.get("eval_count", 0)
    notes = json.loads(r["message"]["content"]).get("notes", [])[:MAX_CANDIDATES]
    return notes, time.time() - t, r.get("prompt_eval_count", 0), r.get("eval_count", 0)


def propose_claude(model, user, so_far, t):
    """Same prompt through headless Claude Code: no tools, no MCP, no saved session."""
    cwd = os.path.join(OUT, "claude-cwd")
    os.makedirs(cwd, exist_ok=True)
    r = subprocess.run(["claude", "-p", "--model", model, "--system-prompt", SYSTEM.format(max=MAX_CANDIDATES),
                        "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                        "--no-session-persistence", "--output-format", "json",
                        "--json-schema", json.dumps(SCHEMA)],
                       input=user, capture_output=True, text=True, cwd=cwd, timeout=900)
    d = json.loads(r.stdout)
    if d.get("is_error") or not d.get("structured_output"):
        raise RuntimeError("claude: %s" % (d.get("subtype") or r.stderr[:200]))
    COST[0] += d.get("total_cost_usd") or 0
    notes = d["structured_output"].get("notes", [])[:MAX_CANDIDATES]
    u = d.get("usage", {})
    return notes, time.time() - t, u.get("input_tokens", 0), u.get("output_tokens", 0)


COST = [0.0]  # list price of headless Claude runs; on a subscription it counts against the plan's limits


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
    path = os.path.join(OUT, "chats.txt")
    chats = [l.split() for l in open(path) if l.strip() and not l.startswith("#")][:a.limit]
    run = datetime.datetime.now().strftime("%Y%m%d-%H%M") + "-" + a.model.replace(":", "-")
    rdir = os.path.join(OUT, run)
    os.makedirs(rdir)
    refs = notes_for([c[0] for c in chats])
    report = ["# Distillation eval %s" % run, "",
              "Model `%s`, think=%s. Fill `labels.csv`: for each proposal good / partial / noise, "
              "and for each chat whether something should have been saved." % (a.model, a.think), ""]
    labels = [["chat_ref", "item", "title", "verdict"]]
    stats = {"chats": 0, "windows": 0, "proposals": 0, "seconds": 0.0, "with_ref": 0, "ref_found": 0}
    for i, c in enumerate(chats, 1):
        ref, meta = c[0], (c[1], c[2])
        # Finished chats are cached per model and prompt, so a rerun after a failure resumes.
        try:
            windows, total, cut = transcript(a.target, ref, [n["title"] for n in refs.get(ref, [])])
        except Exception as e:  # noqa: BLE001 - one bad chat must not stop the run
            print("%2d/%d  error: %s" % (i, len(chats), str(e)[:200]), flush=True)
            report += ["## %d. %s (%s, %s)" % (i, ref, meta[0], meta[1]), "", "Error, skipped.", ""]
            continue
        # A saved note's title in the input means the model can copy it instead of distilling.
        text = "\n".join(windows).lower()
        leak = [n["title"] for n in refs.get(ref, []) if n["title"][:40].lower() in text]
        key = hashlib.sha256((a.model + str(a.think) + SYSTEM + "".join(windows)).encode()).hexdigest()[:16]
        cpath = os.path.join(OUT, "cache", key + ".json")
        if os.path.exists(cpath):
            cached = json.load(open(cpath))
            props = cached["props"]
            stats["windows"] += cached["windows"]
            stats["seconds"] += cached["seconds"]
        else:
            try:
                props, spent = [], 0.0
                for k, w in enumerate(windows, 1):
                    props, sec, pin, pout = propose(a.model, meta, w, a.think, k, len(windows), props)
                    spent += sec
            except Exception as e:  # noqa: BLE001 - one bad chat must not stop the run
                print("%2d/%d  error: %s" % (i, len(chats), str(e)[:200]), flush=True)
                report += ["## %d. %s (%s, %s)" % (i, ref, meta[0], meta[1]), "", "Error, skipped.", ""]
                continue
            os.makedirs(os.path.dirname(cpath), exist_ok=True)
            json.dump({"windows": len(windows), "total": total, "props": props, "seconds": spent,
                       "cut": cut},
                      open(cpath, "w"), ensure_ascii=False)
            stats["windows"] += len(windows)
            stats["seconds"] += spent
        stats["chats"] += 1
        stats["proposals"] += len(props)
        report += ["## %d. %s (%s, %s)" % (i, ref, meta[0], meta[1]),
                   "", "Windows: %d of %d.%s%s" % (len(windows), total, " Transcript " + cut + "." if cut else "",
                                              " LEAK: the saved title is in the input." if leak else ""), ""]
        stats["leaks"] = stats.get("leaks", 0) + bool(leak)
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
            report += ["%d. **%s** (confidence %.2f)" % (j, p["title"], p.get("confidence", 0)), "",
                       p.get("body_md", "").strip(), ""]
            report += ["   - decision: %s" % d for d in p.get("decisions") or []]
            report += ["   - open: %s" % q for q in p.get("open_questions") or []]
            report += [""]
            labels.append([ref, str(j), p["title"][:80], ""])
        labels.append([ref, "chat", "should something be saved? yes / no", ""])
        labels.append([ref, "overall", "would these replace your own note? good / partial / noise", ""])
        print("%2d/%d  windows %d  proposals %d  %s%s%s" % (i, len(chats), len(windows), len(props),
              "ref %.2f" % best if best is not None else ("ref none" if ref in refs else ""),
              "  cut" if cut else "", "  LEAK" if leak else ""), flush=True)
    with open(os.path.join(rdir, "report.md"), "w") as f:
        f.write("\n".join(report) + "\n")
    with open(os.path.join(rdir, "labels.csv"), "w", newline="") as f:
        csv.writer(f).writerows(labels)
    stats["cost_usd"] = round(COST[0], 2)
    with open(os.path.join(rdir, "stats.json"), "w") as f:
        json.dump(stats, f, indent=1)
    print("done: %d chats, %d windows, %d proposals, %.0f s model time; reference notes found %d of %d"
          % (stats["chats"], stats["windows"], stats["proposals"], stats["seconds"],
             stats["ref_found"], stats["with_ref"]))
    if COST[0]:
        print("claude list price: $%.2f" % COST[0])
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
    s.add_argument("--seed", type=int, default=1)
    s = sub.add_parser("run")
    s.add_argument("--model", default="qwen3:8b",
                   help="an Ollama model, or claude:<model> for headless Claude Code (claude:sonnet)")
    s.add_argument("--think", action="store_true", help="let the model reason before answering (slower)")
    s.add_argument("--limit", type=int, help="only the first N chats")
    s = sub.add_parser("score")
    s.add_argument("run")
    a = p.parse_args()
    {"pick": cmd_pick, "run": cmd_run, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
