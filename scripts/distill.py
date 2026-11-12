#!/usr/bin/env python3
"""memohub distiller (A4): proposes notes from finished journal chats; a person approves them.

    distill.py run                 distill chats that are ready (launchd runs this nightly)
    distill.py status              the distiller part of memohub.health()
    distill.py allow SOURCE [PROJECT]   let a source (and optionally one project) be distilled
    distill.py allow --clear       distill nothing
    distill.py resume [--retry-failed]  clear the pause after failed runs; retry failed chats

The database decides what may be read (config distill.allow, empty by default), keeps a cursor
per chat and pauses the distiller after three failed runs. This script fetches each ready chat,
asks the model for notes worth keeping, and hands the parsed answer to memohub._distill_record(),
which creates candidates through _propose(). Nothing becomes a note until a person approves it
(memohub.candidates / approve_candidate).

Messages up to the last save request in a chat are skipped: the user already saved that part
with tomemo. Every database call runs as the owner through the linked Supabase CLI.

Models (MODEL in the config):
    claude:<model>     headless Claude Code (claude -p), e.g. claude:sonnet. No tools, no MCP and
                       no saved session, so the journal scanner never sees these runs. Uses the
                       Claude Code login of this Mac; counts against its plan limits.
    ollama:<model>     a local Ollama model, e.g. ollama:qwen3:8b (OLLAMA_URL, default
                       ~/.memohub/ollama.url, else http://localhost:11434). Weaker notes, but nothing
                       leaves the Mac.

Config: ~/.memohub/distill.conf (KEY=VALUE):
    TARGET=private          private | shared: the database whose journal is distilled
    MODEL=ollama:qwen3:8b   default; claude:sonnet gives much better notes (see above)
    MAX_CHATS=10            per run
    MAX_CHARS=200000        per chat (default 200000 for Claude, 60000 for Ollama's 32k context);
                            a longer chat sends only its newest part
Log: ~/.memohub/distill.log, counts only. Env MEMOHUB_DISTILL_HOME overrides ~/.memohub.
"""

import fcntl
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.request
from datetime import datetime

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser(os.environ.get("MEMOHUB_DISTILL_HOME", "~/.memohub"))
STATE = os.path.join(HOME, "distill")
MAX_NOTES = 3             # per chat
MIN_CONFIDENCE = 0.5      # weaker proposals are dropped before they reach the database
MIN_TAIL_CHARS = 400      # a shorter tail after the last save has nothing new worth a model call
MSG_CHARS = 4000          # long tool output and pasted files are cut
SAVE_REQUEST = re.compile(r"(^|[\s/:])tomemo\b|запомни итог|remember the summary"
                          r"|(сохрани|запиши|добавь)\w*\b.{0,40}\b(memohub|мемохаб)"
                          r"|save\b.{0,30}\bmemohub", re.I | re.S)
SAVED = re.compile(r"memohub\.save|запись сохранена|сохранен\w* в (memohub|мемохаб)|saved (it )?to memohub", re.I)

SYSTEM = """You read a transcript of a chat between a user and an AI assistant and pick out what the user will want to remember months later:
- decisions, with the reason;
- agreements and plans, next steps;
- facts about the user's projects, tools and setup that are not obvious from the code.

Skip routine work: commands, debugging steps, file edits, test runs, anything that only mattered while the chat lasted. Most chats have nothing worth saving; then return an empty list.

A chat that ran in a code repository is partly recorded there already. What was built, merged or released, and what the code, its docs and the assistant's project memory describe (architecture, how a feature works, setup, access, commands, deploy procedures), is not worth a note. What did not reach the repository is: work plans and next steps, problems and challenges still open, ideas and changes that were discussed but not built, deferred or not started, options rejected with the reason, decisions waiting for someone's answer, agreements with people. If everything in the chat was built and documented, return an empty list.

One note per topic, with every decision on that topic in it; never split a topic across notes or repeat a point in two notes. Most chats have one topic. At most {max} notes. Notes already saved from this chat are listed; do not propose them again.

Each note:
- title: specific, under 120 characters;
- space and project: from the catalog given; project may be null;
- body_md: short markdown with the context and the outcome, in your own words. No quotes from the chat;
- decisions: each one understandable without the chat and ending with its reason ("..., because ..."). Decisions not to do something, or to wait, count too and are often the most useful;
- open_questions: what is still open, if anything;
- sources: the numbers [n] of the messages the note is based on;
- confidence: 0..1, how sure you are the user would keep this note.

Do not attribute words or positions to anyone unless the transcript says plainly who said them; text the user drafts or pastes for a reply is the user's. Do not add numbers, limits or rules that are not in the transcript.

Write in the language of the chat. Never include secrets, passwords, tokens, connection strings, card, account or document numbers, addresses or phone numbers; text like [masked:...] stays out of the note."""

SCHEMA = {
    "type": "object",
    "properties": {"notes": {"type": "array", "maxItems": MAX_NOTES, "items": {
        "type": "object",
        "properties": {
            "title": {"type": "string"},
            "space": {"type": "string"},
            "project": {"type": ["string", "null"]},
            "body_md": {"type": "string"},
            "decisions": {"type": "array", "items": {"type": "string"}},
            "open_questions": {"type": "array", "items": {"type": "string"}},
            "sources": {"type": "array", "items": {"type": "integer"}},
            "confidence": {"type": "number"},
        },
        "required": ["title", "space", "body_md", "decisions", "sources", "confidence"],
    }}},
    "required": ["notes"],
}


def default_max_chars(model):
    """Characters of transcript per chat: Ollama runs with a 32k-token context."""
    return 60000 if model.startswith("ollama:") else 200000


def load_conf():
    conf = {"TARGET": "private", "MODEL": "ollama:qwen3:8b", "MAX_CHATS": "10"}
    path = os.path.join(HOME, "distill.conf")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip().strip('"').strip("'")
    if conf["TARGET"] not in ("private", "shared"):
        sys.exit("distill.conf: TARGET must be private|shared")
    if not re.match(r"^(claude|ollama):\S+$", conf["MODEL"]):
        sys.exit("distill.conf: MODEL must be claude:<model> or ollama:<model>")
    conf["MAX_CHATS"] = int(conf["MAX_CHATS"])
    conf["MAX_CHARS"] = int(conf.get("MAX_CHARS") or default_max_chars(conf["MODEL"]))
    return conf


def log(msg):
    line = "%s %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        with open(os.path.join(HOME, "distill.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------- database

def call(conf, fn, *args):
    """select memohub.<fn>(args...) as the owner through the linked CLI; return the jsonb result.
    Arguments are passed as dollar-quoted literals; types come from the function signature."""
    tag = "d_" + secrets.token_hex(6)
    parts = []
    for a in args:
        if a is None:
            parts.append("null")
        else:
            s = a if isinstance(a, str) else json.dumps(a, ensure_ascii=False)
            if "$" + tag + "$" in s:
                raise RuntimeError("dollar-quote tag collision")
            parts.append("$%s$%s$%s$" % (tag, s, tag))
    sql = "select memohub.%s(%s) as r\n" % (fn, ", ".join(parts))
    workdir = REPO if conf["TARGET"] == "shared" else os.path.join(REPO, "targets", "private")
    os.makedirs(STATE, exist_ok=True)
    for attempt in range(3):
        fd, path = tempfile.mkstemp(suffix=".sql", dir=STATE)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(sql)
            out = subprocess.run(["supabase", "--workdir", workdir, "db", "query", "--linked",
                                  "--output-format", "json", "-f", path],
                                 capture_output=True, text=True, timeout=600)
        finally:
            os.unlink(path)
        m = re.search(r"^[\[{]", out.stdout, re.M) if out.returncode == 0 else None
        if m:
            break
        if attempt == 2:
            err = [l for l in out.stderr.splitlines() if "Initialising login role" not in l]
            raise RuntimeError(("\n".join(err) or "supabase CLI failed").strip()[-300:])
        time.sleep(15 * (attempt + 1))
    data = json.loads(out.stdout[m.start():])
    r = (data["rows"] if isinstance(data, dict) else data)[0]["r"]
    return json.loads(r) if isinstance(r, str) else r


# ---------------------------------------------------------------- model

def ask_claude(model, system, user):
    cwd = os.path.join(STATE, "claude-cwd")
    os.makedirs(cwd, exist_ok=True)
    r = subprocess.run(["claude", "-p", "--model", model, "--system-prompt", system,
                        "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                        "--no-session-persistence", "--output-format", "json",
                        "--json-schema", json.dumps(SCHEMA)],
                       input=user, capture_output=True, text=True, cwd=cwd, timeout=900)
    try:
        d = json.loads(r.stdout)
    except ValueError:
        raise RuntimeError("claude: %s" % (r.stderr.strip() or r.stdout.strip())[-200:])
    if d.get("is_error") or not isinstance(d.get("structured_output"), dict):
        raise RuntimeError("claude: %s" % (d.get("subtype") or "no structured output"))
    return d["structured_output"].get("notes") or [], float(d.get("total_cost_usd") or 0)


def ask_ollama(model, system, user):
    base = os.environ.get("OLLAMA_URL")
    if not base and os.path.exists(os.path.join(HOME, "ollama.url")):
        base = open(os.path.join(HOME, "ollama.url")).read().strip()
    base = (base or "http://localhost:11434").rstrip("/")
    body = {"model": model, "stream": False, "think": False, "format": SCHEMA,
            "options": {"num_ctx": 32768, "temperature": 0.2, "num_predict": 3000, "repeat_penalty": 1.1},
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    req = urllib.request.Request(base + "/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as resp:
        d = json.loads(resp.read())
    if d.get("done_reason") == "length":
        raise RuntimeError("ollama: answer cut")
    return json.loads(d["message"]["content"]).get("notes") or [], 0.0


def ask(conf, system, user):
    kind, model = conf["MODEL"].split(":", 1)
    return (ask_claude if kind == "claude" else ask_ollama)(model, system, user)


# ---------------------------------------------------------------- one chat

def norm(name):
    return re.sub(r"[\s_]+", "-", (name or "").strip().lower())


def load_catalog(conf):
    """Spaces with their projects from this database and, from the private one, the shared one
    too: work projects live in the shared catalog, and a work candidate is saved there."""
    spaces = {}
    targets = [conf["TARGET"]] + (["shared"] if conf["TARGET"] == "private" else [])
    for t in targets:
        try:
            cat = call(dict(conf, TARGET=t), "catalog")
        except Exception as e:  # noqa: BLE001 - the shared catalog only adds project names
            if t == conf["TARGET"]:
                raise
            log("shared catalog not read: %s" % str(e)[:120])
            continue
        for sp in cat.get("spaces") or []:
            projects = spaces.setdefault(sp["slug"], {})
            for p in sp.get("projects") or []:
                projects.setdefault(p["slug"], {norm(p["slug"])} | {norm(a) for a in p.get("aliases") or []})
    return spaces


def project_of(hint, spaces):
    """(space, project) whose slug or alias is the chat's folder name, if exactly one matches."""
    h = norm(hint)
    found = [(sp, slug) for sp, projects in spaces.items() for slug, names in projects.items() if h and h in names]
    return found[0] if len(found) == 1 else None


def build_input(chat, pending, catalog, max_chars):
    """Numbered transcript after the last save request, and the capture ids it covers."""
    msgs = chat["messages"]
    start = 0
    for i, m in enumerate(msgs):
        if (m["role"] == "user" and SAVE_REQUEST.search(m["content"])) or SAVED.search(m["content"]):
            start = i + 1
    tail = msgs[start:]
    lines, total = [], 0
    for n in range(len(tail) - 1, -1, -1):        # newest first, until the size limit
        text = tail[n]["content"]
        if len(text) > MSG_CHARS:
            text = text[:MSG_CHARS] + " [...cut]"
        line = "[%d] %s: %s" % (n + 1, tail[n]["role"], text)
        if lines and total + len(line) > max_chars:
            break
        lines.append(line)
        total += len(line)
    lines.reverse()
    spaces = [{"space": sp, "projects": sorted(projects)} for sp, projects in sorted(catalog.items())]
    match = project_of(pending.get("project_hint"), catalog)
    folder = pending.get("project_hint") or "none"
    if match:
        folder += " (project %s in space %s)" % (match[1], match[0])
    user = ("Source: %s. Project folder: %s.\n\nCatalog (space -> projects):\n%s\n\n"
            "Notes already saved from this chat:\n%s\n\n<transcript>\n%s\n</transcript>") % (
        pending["source"], folder,
        json.dumps(spaces, ensure_ascii=False),
        "\n".join("- " + t for t in chat.get("saved_titles") or []) or "none",
        "\n\n".join(lines))
    return tail, total, user


def to_candidates(notes, tail, catalog, hint=None):
    """Validate the model's notes and turn them into _propose() input. A note without a valid
    project gets the project of the chat's folder when it is in the same space."""
    spaces = catalog
    match = project_of(hint, catalog)
    out, dropped = [], 0
    for note in notes[:MAX_NOTES]:
        space, project = note.get("space"), note.get("project")
        ids = [tail[n - 1]["id"] for n in note.get("sources") or [] if isinstance(n, int) and 1 <= n <= len(tail)]
        if (space not in spaces or float(note.get("confidence") or 0) < MIN_CONFIDENCE
                or not (note.get("title") or "").strip() or not ids):
            dropped += 1
            continue
        payload = {"space": space, "title": note["title"].strip()[:200],
                   "type": "decision" if note.get("decisions") else "note",
                   "body_md": note.get("body_md") or "",
                   "decisions": note.get("decisions") or [],
                   "open_questions": note.get("open_questions") or []}
        if project in spaces[space]:
            payload["project"] = project
        elif match and match[0] == space:
            payload["project"] = match[1]
        out.append({"kind": "new", "confidence": note.get("confidence"), "payload": payload,
                    "capture_ids": sorted(set(ids))})
    return out, dropped


def ts(value):
    """Postgres timestamps as datetimes. Python 3.9 (the system python3 that launchd runs)
    accepts only 3 or 6 fraction digits, and Postgres drops trailing zeros (.92)."""
    m = re.match(r"^(.*?)(?:\.(\d+))?(Z|[+-]\d\d(?::?\d\d)?)?$", value.strip())
    zone = (m.group(3) or "+00:00").replace("Z", "+00:00")
    zone = zone[:3] + ":" + (zone[3:].lstrip(":") or "00")
    return datetime.fromisoformat("%s.%s%s" % (m.group(1), (m.group(2) or "0").ljust(6, "0")[:6], zone))


def covered(conf, cands, chat_end):
    """Drop candidates whose topic already has a note saved after the chat's last message, in
    this database or the shared one: that note covers it. Older similar notes are left for the
    person: approval through save() offers to amend them."""
    targets = [conf["TARGET"]] + (["shared"] if conf["TARGET"] == "private" else [])
    keep = []
    for c in cands:
        newer = False
        for t in targets:
            try:
                found = call(dict(conf, TARGET=t), "_distill_similar", c["payload"]["space"], c["payload"]["title"])
            except Exception as e:  # noqa: BLE001 - without the check the person still sees similar_exists
                if t == conf["TARGET"]:
                    raise
                log("shared similarity check failed: %s" % str(e)[:120])
                continue
            if any(ts(n["created_at"]) >= chat_end for n in found):
                newer = True
                break
        if not newer:
            keep.append(c)
    return keep


def distill_chat(conf, run, pending, catalog):
    chat = call(conf, "_distill_chat", pending["chat_ref"])
    sent = [m["id"] for m in chat["messages"]]
    if not sent:
        return 0, 0.0
    tail, size, user = build_input(chat, pending, catalog, conf["MAX_CHARS"])
    if size < MIN_TAIL_CHARS:                     # nothing new since the last save
        r = call(conf, "_distill_record", run, pending["chat_ref"], "{%s}" % ",".join(sent), [], 0)
        if not r.get("ok"):
            raise RuntimeError("record: %s" % r.get("error"))
        return 0, 0.0
    cost = 0.0
    try:
        notes, cost = ask(conf, SYSTEM.format(max=MAX_NOTES), user)
        cands, dropped = to_candidates(notes, tail, catalog, pending.get("project_hint"))
        cands = covered(conf, cands, max(ts(m["event_at"]) for m in tail))
    except Exception as e:  # noqa: BLE001 - recorded per chat; three in a row mark it failed
        call(conf, "_distill_fail", run, pending["chat_ref"], str(e)[:300], cost)
        raise
    r = call(conf, "_distill_record", run, pending["chat_ref"], "{%s}" % ",".join(sent), cands, cost)
    if not r.get("ok"):
        raise RuntimeError("record: %s" % r.get("error"))
    return len(r.get("proposed") or []), cost


# ---------------------------------------------------------------- commands

def cmd_run(conf):
    os.makedirs(STATE, exist_ok=True)
    lock = open(os.path.join(STATE, "run.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another run is going")
        return 0
    r = call(conf, "_distill_begin", conf["MODEL"])
    if not r.get("ok"):
        log("not started: %s" % r.get("error"))
        return 0
    run = r["run"]
    proposed = chats = errors = 0
    cost = 0.0
    error = None
    try:
        catalog = load_catalog(conf)
        pending = call(conf, "_distill_pending", conf["MAX_CHATS"])
        for p in pending:
            try:
                n, c = distill_chat(conf, run, p, catalog)
                proposed, cost, chats = proposed + n, cost + c, chats + 1
            except Exception as e:  # noqa: BLE001 - one bad chat must not stop the run
                errors += 1
                log("chat failed: %s" % str(e)[:200])
        if pending and errors == len(pending):
            error = "every chat failed"
    except Exception as e:  # noqa: BLE001
        error = str(e)[:300]
    fin = call(conf, "_distill_finish", run, error)
    log("run %s: %d chats, %d candidates, %d errors, $%.2f list price%s%s" % (
        run[:8], chats, proposed, errors, cost, " - failed: " + error if error else "",
        " - paused after 3 failed runs" if fin.get("paused") else ""))
    return 1 if error else 0


def cmd_status(conf):
    print(json.dumps(call(conf, "health", 7).get("distill"), ensure_ascii=False, indent=1))
    return 0


def cmd_allow(conf, args):
    if args == ["--clear"]:
        r = call(conf, "_distill_allow", [])
    elif 1 <= len(args) <= 2:
        cur = call(conf, "_distill_allow", None)["allow"]
        entry = {"source": args[0], "project": args[1] if len(args) > 1 else None}
        r = call(conf, "_distill_allow", cur + [entry] if entry not in cur else cur)
    else:
        sys.exit("usage: distill.py allow SOURCE [PROJECT] | --clear")
    if not r.get("ok"):
        sys.exit("allow: %s" % r.get("error"))
    print(json.dumps(r["allow"], ensure_ascii=False))
    return 0


def cmd_resume(conf, args):
    r = call(conf, "_distill_resume", "true" if args == ["--retry-failed"] else "false")
    print(json.dumps(r, ensure_ascii=False))
    return 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("run", "status", "allow", "resume"):
        sys.exit(__doc__)
    conf = load_conf()
    if sys.argv[1] == "run":
        return cmd_run(conf)
    if sys.argv[1] == "status":
        return cmd_status(conf)
    if sys.argv[1] == "resume":
        return cmd_resume(conf, sys.argv[2:])
    return cmd_allow(conf, sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
