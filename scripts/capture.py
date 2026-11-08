#!/usr/bin/env python3
"""memohub capture scanner (A1): raw chat journal from local transcripts.

    capture.py run        scan sources, spool new messages, send the spool
    capture.py scan       scan and spool only (no network)
    capture.py send       send the spool only
    capture.py status     local state: cursors, spool, last run

Reads Claude Code transcripts (~/.claude/projects/*/*.jsonl), Codex sessions
(~/.codex/sessions/**/*.jsonl) and meeting transcripts (~/Documents/Meetings/*.txt), keeps only
user/assistant text, masks card numbers, IBAN, passport, SNILS and credentials (same patterns
as memohub._mask_sensitive, tests/mask_cases.json), applies #nomemo / #memo, and sends batches
to memohub.capture_batch() through the linked Supabase CLI as the owner.

No message is lost on a crash: new lines go to a durable local spool first, the file cursor
moves only after that, and spool items leave only when the database acknowledges their keys.

Config: ~/.memohub/capture.conf (KEY=VALUE):
    DEVICE=home-mac                 required
    TARGET=private                  private (home Mac) | shared (work laptop)
    MODE=all                        all | projects (only PROJECTS and chats with #memo)
    PROJECTS=agent_platform,airflow_etl
    SOURCES=claude-code,codex,meeting
    MEETINGS_DIR=~/Documents/Meetings
State: ~/.memohub/capture/ (cursors.json, chats.json, spool.jsonl, rejected.jsonl), log
~/.memohub/capture.log. Env MEMOHUB_CAPTURE_HOME overrides ~/.memohub (tests).
"""

import fcntl
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser(os.environ.get("MEMOHUB_CAPTURE_HOME", "~/.memohub"))
STATE = os.path.join(HOME, "capture")
CHUNK = 50000           # characters per stored piece; the database accepts up to 60000
BATCH = 1000            # items per capture_batch call
MEETING_SETTLE = 600    # seconds a meeting transcript must be unchanged before capture
TAG = {name: re.compile(r"(?<!\S)#" + name + r"(?![\w-])", re.I) for name in ("nomemo", "memo", "shared")}
# Text the user did not type: pasted blocks and command output. Tags inside do not count.
NOT_TYPED = re.compile(r"<(pasted_content|bash-stdout|bash-stderr|local-command-stdout|local-command-stderr)\b[^>]*>"
                       r".*?(?:</\1>|\Z)", re.S)


def has_tag(name, text):
    return bool(text) and bool(TAG[name].search(NOT_TYPED.sub(" ", text)))


# ---------------------------------------------------------------- masking (keep in step with SQL)

def _luhn_ok(d):
    total = 0
    for i, ch in enumerate(reversed(d)):
        n = int(ch)
        if i % 2:
            n *= 2
            if n > 9:
                n -= 9
        total += n
    return total % 10 == 0


DATETIME_DIGITS = re.compile(r"(19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])([01]\d|2[0-3])[0-5]\d[0-5]\d(\d{3})?")


def _is_card_number(m):
    """Luhn-valid 13-19 digits, except a bare 14/17-digit date-time stamp (migration versions,
    Shortcut ids); same rule as memohub._is_card_number."""
    d = re.sub(r"\D", "", m)
    if not (13 <= len(d) <= 19 and _luhn_ok(d)):
        return False
    return not (m == d and len(d) in (14, 17) and DATETIME_DIGITS.fullmatch(d))


def _iban_ok(raw):
    s = raw.replace(" ", "").upper()
    if not re.fullmatch(r"[A-Z]{2}\d{2}[A-Z0-9]{11,30}", s):
        return False
    s = s[4:] + s[:4]
    num = "".join(str(int(c, 36)) for c in s)
    return int(num) % 97 == 1


CRED_PATTERNS = [
    r"sk-[A-Za-z0-9_-]{20,}",
    r"sk_(?:live|test)_[A-Za-z0-9]{16,}",
    r"gh[pousr]_[A-Za-z0-9]{30,}", r"github_pat_[A-Za-z0-9_]{30,}",
    r"xox[abprs]-[A-Za-z0-9-]{10,}",
    r"AKIA[0-9A-Z]{16}",
    r"sbp_[a-f0-9]{40}",
    r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
]


def mask(t):
    """Return (masked text, sorted list of kinds)."""
    kinds = set()
    if not t:
        return t or "", []
    before = t
    t = re.sub(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[A-Za-z0-9+/=\s]*(?:-----END [A-Z ]*PRIVATE KEY-----)?",
               "[masked:credential]", t)
    if t != before:
        kinds.add("credential")
    for m in sorted(set(re.findall(r"(?:\d[ -]?){12,18}\d", t)), key=len, reverse=True):
        if _is_card_number(m):
            t = t.replace(m, "[masked:card_number]")
            kinds.add("card_number")
    for m in sorted(set(re.findall(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}", t)), key=len, reverse=True):
        if _iban_ok(m):
            t = t.replace(m, "[masked:iban]")
            kinds.add("iban")
    before = t
    t = re.sub(r"((?:паспорт|passport)\D{0,30})\d{2} ?\d{2} ?\d{6}", r"\1[masked:passport_number]", t, flags=re.I)
    if t != before:
        kinds.add("passport_number")
    before = t
    t = re.sub(r"\b\d{3}-\d{3}-\d{3}[ -]\d{2}\b", "[masked:snils]", t)
    if t != before:
        kinds.add("snils")
    before = t
    for pat in CRED_PATTERNS:
        t = re.sub(pat, "[masked:credential]", t)
    t = re.sub(r"([a-z][a-z0-9+.-]*://)[^\s:/@]+:[^\s@/]+@", r"\1[masked:credential]@", t)
    t = re.sub(r"((?:password|passwd|pwd|пароль)\s*[:=]\s*)\S{4,}", r"\1[masked:credential]", t, flags=re.I)
    if t != before:
        kinds.add("credential")
    return t, sorted(kinds)


# ---------------------------------------------------------------- config and state

def load_conf():
    conf = {"TARGET": "private", "MODE": "all", "PROJECTS": "", "SOURCES": "claude-code,codex,meeting",
            "MEETINGS_DIR": "~/Documents/Meetings",
            "CLAUDE_DIR": "~/.claude/projects", "CODEX_DIR": "~/.codex/sessions"}
    path = os.path.join(HOME, "capture.conf")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip().strip('"').strip("'")
    if not conf.get("DEVICE"):
        sys.exit("capture.conf: DEVICE is required (e.g. DEVICE=home-mac)")
    if conf["TARGET"] not in ("private", "shared") or conf["MODE"] not in ("all", "projects"):
        sys.exit("capture.conf: TARGET must be private|shared, MODE all|projects")
    conf["projects"] = {p.strip().lower() for p in conf["PROJECTS"].split(",") if p.strip()}
    conf["sources"] = {s.strip() for s in conf["SOURCES"].split(",") if s.strip()}
    return conf


def load_json(name, default):
    path = os.path.join(STATE, name)
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def save_json(name, data):
    """Atomic write: temp file in the same directory, fsync, rename."""
    path = os.path.join(STATE, name)
    fd, tmp = tempfile.mkstemp(dir=STATE, prefix="." + name)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def read_spool():
    path = os.path.join(STATE, "spool.jsonl")
    items = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if line.strip():
                try:
                    it = json.loads(line)
                except ValueError:
                    continue            # a torn last line from a crash; its source is re-read
                items[it["key"]] = it
    return items


def write_spool(items):
    path = os.path.join(STATE, "spool.jsonl")
    fd, tmp = tempfile.mkstemp(dir=STATE, prefix=".spool")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        for it in items.values():
            f.write(json.dumps(it, ensure_ascii=False) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def log(msg):
    line = "%s %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line)
    try:
        with open(os.path.join(HOME, "capture.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------- transcript parsing

SKIP_USER_PREFIXES = ("<task-notification>", "<system-reminder>", "<local-command-caveat>",
                      "<environment_context>", "<user_instructions>", "<user_action>", "# AGENTS.md")


def _claude_message(rec):
    """(role, text) for a user/assistant text message of a Claude Code transcript, else None."""
    if rec.get("type") not in ("user", "assistant") or rec.get("isMeta") or rec.get("isSidechain") \
            or rec.get("isCompactSummary") or "toolUseResult" in rec:
        return None
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    else:
        return None
    text = text.strip()
    if not text or (rec["type"] == "user" and text.startswith(SKIP_USER_PREFIXES)):
        return None
    return rec["type"], text


def _codex_message(rec):
    if rec.get("type") != "response_item":
        return None
    p = rec.get("payload") or {}
    if p.get("type") != "message" or p.get("role") not in ("user", "assistant"):
        return None
    text = "\n".join(c.get("text", "") for c in p.get("content") or []
                     if isinstance(c, dict) and c.get("type") in ("input_text", "output_text", "text")).strip()
    if not text or (p["role"] == "user" and text.startswith(SKIP_USER_PREFIXES)):
        return None
    return p["role"], text


def read_new_lines(path, cur):
    """Complete lines after cur['offset'] (a torn last line waits for the next run)."""
    with open(path, "rb") as f:
        f.seek(cur["offset"])
        data = f.read()
    end = data.rfind(b"\n")
    if end < 0:
        return [], cur["offset"]
    lines = data[:end + 1].split(b"\n")[:-1]
    out = []
    pos = cur["offset"]
    for raw in lines:
        out.append((pos, raw))
        pos += len(raw) + 1
    return out, pos


def chunks(text):
    return [text[i:i + CHUNK] for i in range(0, len(text), CHUNK)] or [""]


# ---------------------------------------------------------------- per-chat decision

def decide(chat, conf, first_user_text, project):
    """Called once per chat at its first user message: capture or skip on this device."""
    if conf["MODE"] == "all":
        return "capture"
    if project and project.lower() in conf["projects"]:
        return "capture"
    if has_tag("memo", first_user_text):
        return "capture"
    return "skip"


class Scan:
    def __init__(self, conf):
        self.conf = conf
        self.cursors = load_json("cursors.json", {})
        self.chats = load_json("chats.json", {})
        self.spool = read_spool()
        self.suppress = set(load_json("suppress_pending.json", []))
        self.new_items = 0
        self.errors = {}
        self.missing = []

    # -- generic transcript file (Claude Code, Codex)
    def scan_file(self, path, source, chat_of, message_of, key_of):
        st = os.stat(path)
        cur = self.cursors.get(path)
        if cur and cur.get("inode") == st.st_ino and cur.get("size") == st.st_size:
            return
        if not cur or cur.get("inode") != st.st_ino or st.st_size < cur.get("offset", 0):
            if cur:
                log("restart %s (replaced or truncated); duplicates are dropped by key" % path)
            cur = {"inode": st.st_ino, "offset": 0, "size": 0, "chat_ref": None, "project": None}
        lines, new_offset = read_new_lines(path, cur)
        # One file can hold several chats: Claude Code copies the parent session's records (with
        # their own sessionId and uuid) into a continued session's file. Chat per record.
        by_chat = {}
        for pos, raw in lines:
            try:
                rec = json.loads(raw)
            except ValueError:
                continue
            meta = chat_of(rec)
            if meta:
                cur["chat_ref"], cur["project"] = meta.get("chat_ref"), meta.get("project") or cur.get("project")
            m = message_of(rec)
            chat = cur.get("chat_ref")
            if m and chat:
                entry = by_chat.setdefault(chat, (cur.get("project"), []))
                role, text = m
                entry[1].append((key_of(chat, pos, rec, text), role, rec.get("timestamp"), pos, text))
        for chat, (project, msgs) in by_chat.items():
            self._take(source, chat, project, msgs)
        cur.update(offset=new_offset, size=st.st_size if new_offset == st.st_size else new_offset)
        # Spool first, then the cursor: a crash in between only re-reads lines (same keys).
        write_spool(self.spool)
        save_json("chats.json", self.chats)
        save_json("suppress_pending.json", sorted(self.suppress))
        self.cursors[path] = cur
        save_json("cursors.json", self.cursors)

    def _take(self, source, chat, project, msgs):
        st = self.chats.get(chat)
        user_texts = [t for _, role, _, _, t in msgs if role == "user"]
        if st is None:
            st = {"decision": decide(chat, self.conf, user_texts[0] if user_texts else None, project)
                  if user_texts or self.conf["MODE"] == "all" else None, "source": source}
            self.chats[chat] = st
        if any(has_tag("nomemo", t) for t in user_texts):
            if st.get("decision") != "suppressed":
                log("#nomemo in %s: nothing more is sent, captured part is deleted" % chat)
            st["decision"] = "suppressed"
            self.suppress.add(chat)
            for k in [k for k, it in self.spool.items() if it["chat_ref"] == chat]:
                del self.spool[k]
            return
        if st.get("decision") is None and (user_texts or self.conf["MODE"] == "all"):
            st["decision"] = decide(chat, self.conf, user_texts[0] if user_texts else None, project)
        if st.get("decision") != "capture":
            return
        for key, role, ts, seq, text in msgs:
            masked, _ = mask(text)
            for i, piece in enumerate(chunks(masked)):
                k = key if i == 0 else "%s#%d" % (key, i)
                self.spool[k] = {"key": k, "source": source, "chat_ref": chat, "project_hint": project,
                                 "role": role, "event_at": ts, "seq": seq, "part": i, "content": piece}
                self.new_items += 1

    # -- sources
    def scan_claude(self):
        base = os.path.expanduser(self.conf["CLAUDE_DIR"])
        try:
            dirs = sorted(os.listdir(base))
        except OSError:
            return
        for d in dirs:
            dpath = os.path.join(base, d)
            if not os.path.isdir(dpath):
                continue
            for name in sorted(os.listdir(dpath)):
                if name.endswith(".jsonl"):
                    self._safe("claude-code", os.path.join(dpath, name), self._claude_file)

    def _claude_file(self, path):
        self.scan_file(
            path, "claude-code",
            lambda r: {"chat_ref": "cc-" + r["sessionId"],
                       "project": os.path.basename(r.get("cwd") or "") or None} if r.get("sessionId") else None,
            _claude_message,
            lambda chat, pos, r, text: "%s:%s" % (chat, r.get("uuid") or pos))

    def scan_codex(self):
        base = os.path.expanduser(self.conf["CODEX_DIR"])
        for root, _, files in os.walk(base):
            for name in sorted(files):
                if name.endswith(".jsonl"):
                    self._safe("codex", os.path.join(root, name), self._codex_file)

    def _codex_file(self, path):
        def chat_of(r):
            if r.get("type") == "session_meta":
                p = r.get("payload") or {}
                sid = p.get("id") or p.get("session_id")
                if sid:
                    return {"chat_ref": "codex-" + sid, "project": os.path.basename(p.get("cwd") or "") or None}
            return None
        self.scan_file(path, "codex", chat_of, _codex_message,
                       lambda chat, pos, r, text: "%s:%s" % (chat, (r.get("payload") or {}).get("id")
                                                             or "%d:%s" % (pos, hashlib.sha256(text.encode()).hexdigest()[:12])))

    def scan_meetings(self):
        base = os.path.expanduser(self.conf["MEETINGS_DIR"])
        try:
            names = sorted(os.listdir(base))
        except FileNotFoundError:
            return
        except OSError as e:            # e.g. macOS privacy protection of ~/Documents under launchd
            self.errors["meeting"] = "%s: %s" % (base, e.strerror or e)
            log("error meeting %s: %s" % (base, e))
            return
        for name in names:
            m = re.fullmatch(r"(\d{4}-\d{2}-\d{2}_\d{2}-\d{2})\.txt", name)
            if m:
                self._safe("meeting", os.path.join(base, name), self._meeting_file)

    def _meeting_file(self, path):
        st = os.stat(path)
        cur = self.cursors.get(path)
        if cur and cur.get("size") == st.st_size:
            return
        if time.time() - st.st_mtime < MEETING_SETTLE:
            return                      # still being transcribed
        stem = os.path.basename(path)[:-4]
        chat = "meeting-" + stem
        try:
            ts = datetime.strptime(stem, "%Y-%m-%d_%H-%M").astimezone().isoformat()
        except ValueError:
            ts = None
        text = open(path, encoding="utf-8", errors="replace").read()
        slides = os.path.join(os.path.dirname(path), stem + "-slides", "slides.json")
        if os.path.exists(slides):
            try:
                data = json.load(open(slides, encoding="utf-8"))
                rows = data if isinstance(data, list) else data.get("slides", [])
                stext = "\n\n".join("Slide %s: %s" % (s.get("index", i + 1), (s.get("text") or "").strip())
                                    for i, s in enumerate(rows) if isinstance(s, dict) and (s.get("text") or "").strip())
                if stext:
                    text += "\n\n--- Slides ---\n" + stext
            except (ValueError, OSError):
                pass
        if not self.chats.get(chat):
            self.chats[chat] = {"decision": "capture" if self.conf["MODE"] == "all" else "skip", "source": "meeting"}
        if self.chats[chat]["decision"] == "capture":
            masked, _ = mask(text)
            digest = hashlib.sha256(text.encode()).hexdigest()[:12]
            for i, piece in enumerate(chunks(masked)):
                k = "%s:%s:%d" % (chat, digest, i)
                self.spool[k] = {"key": k, "source": "meeting", "chat_ref": chat, "project_hint": None,
                                 "role": "transcript", "event_at": ts, "seq": 0, "part": i, "content": piece}
                self.new_items += 1
        write_spool(self.spool)
        save_json("chats.json", self.chats)
        self.cursors[path] = {"inode": st.st_ino, "size": st.st_size, "offset": st.st_size, "chat_ref": chat}
        save_json("cursors.json", self.cursors)

    def _safe(self, source, path, fn):
        try:
            fn(path)
        except FileNotFoundError:
            pass                        # deleted between listing and reading
        except Exception as e:          # one bad file must not stop the others
            self.errors[source] = "%s: %s" % (os.path.basename(path), e)
            log("error %s %s: %s" % (source, path, e))

    def run(self):
        sources = self.conf["sources"]
        if "claude-code" in sources:
            self.scan_claude()
        if "codex" in sources:
            self.scan_codex()
        if "meeting" in sources:
            self.scan_meetings()
        for path, cur in self.cursors.items():
            if not os.path.exists(path) and not cur.get("gone"):
                cur["gone"] = datetime.now(timezone.utc).isoformat()
                self.missing.append(path)
        save_json("cursors.json", self.cursors)
        save_json("last_scan.json", {"at": datetime.now(timezone.utc).isoformat(), "new_items": self.new_items,
                                     "errors": self.errors, "missing": self.missing})
        return self


# ---------------------------------------------------------------- sending

def _workdir(conf):
    return REPO if conf["TARGET"] == "shared" else os.path.join(REPO, "targets", "private")


def call_batch(conf, payload):
    """Run memohub.capture_batch(payload) as the owner via the linked CLI; return its result."""
    sender = os.environ.get("MEMOHUB_CAPTURE_SENDER")
    if sender:                          # tests: a command that reads the payload on stdin
        out = subprocess.run(sender, shell=True, input=json.dumps(payload), capture_output=True, text=True)
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip()[-300:])
        return json.loads(out.stdout)
    tag = "cap_" + secrets.token_hex(6)
    body = json.dumps(payload, ensure_ascii=False)
    if "$" + tag + "$" in body:
        raise RuntimeError("dollar-quote tag collision")
    fd, sql = tempfile.mkstemp(suffix=".sql", dir=STATE)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("select memohub.capture_batch($%s$%s$%s$::jsonb) as r\n" % (tag, body, tag))
        out = subprocess.run(["supabase", "--workdir", _workdir(conf), "db", "query", "--linked",
                              "--output-format", "json", "-f", sql],
                             capture_output=True, text=True, timeout=600)
    finally:
        os.unlink(sql)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[-300:])
    m = re.search(r"^[\[{]", out.stdout, re.M)
    if not m:
        raise RuntimeError("no JSON in CLI output")
    data = json.loads(out.stdout[m.start():])
    rows = data["rows"] if isinstance(data, dict) else data
    r = rows[0]["r"]
    return json.loads(r) if isinstance(r, str) else r


def send(conf):
    """Send spooled items in batches; drop only what the database acknowledged."""
    spool = read_spool()
    suppress = load_json("suppress_pending.json", [])
    last = load_json("last_scan.json", {})
    sent_status = load_json("last_send.json", {})
    # Nothing to send: report the source status at most hourly (each CLI call costs 10-60 s).
    if not spool and not suppress and time.time() - sent_status.get("status_at", 0) < 3600:
        return 0, 0
    errors = last.get("errors", {})
    sources = [{"source": s, "scanned_at": last.get("at"), "error": errors.get(s),
                "cursor": {"pending": sum(1 for it in spool.values() if it["source"] == s),
                           "missing_files": len(last.get("missing", []))}}
               for s in sorted(conf["sources"])]
    sent = inserted = 0
    first = True
    while first or spool:
        batch = list(spool.values())[:BATCH]
        payload = {"device": conf["DEVICE"], "items": batch}
        if first:
            payload["suppress"] = suppress
            payload["sources"] = sources
        r = call_batch(conf, payload)
        if not r.get("ok"):
            raise RuntimeError("capture_batch: %s" % r)
        if first and sorted(r.get("suppressed_chats") or []) != sorted(suppress):
            raise RuntimeError("suppression not confirmed: %s" % r.get("suppressed_chats"))
        if first:
            save_json("suppress_pending.json", [])
            save_json("last_send.json", {"status_at": time.time()})
            first = False
        acked = set(r.get("acked") or [])
        rejected = r.get("rejected") or []
        if rejected:
            with open(os.path.join(STATE, "rejected.jsonl"), "a", encoding="utf-8") as f:
                for rej in rejected:
                    f.write(json.dumps({"rejected": rej, "item": spool.get(rej.get("key"))}, ensure_ascii=False) + "\n")
                    acked.add(rej.get("key"))
            log("rejected %d item(s), see capture/rejected.jsonl" % len(rejected))
        for k in acked:
            spool.pop(k, None)
        write_spool(spool)
        sent += len(batch)
        inserted += r.get("inserted", 0)
        if batch and not acked:
            raise RuntimeError("database acknowledged nothing; spool kept")
    return sent, inserted


# ---------------------------------------------------------------- main

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    os.makedirs(STATE, exist_ok=True)
    lock = open(os.path.join(STATE, ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("another capture run is in progress")
        return 0
    conf = load_conf()
    if cmd == "status":
        cur = load_json("cursors.json", {})
        print(json.dumps({"device": conf["DEVICE"], "target": conf["TARGET"], "mode": conf["MODE"],
                          "files": len(cur), "spool": len(read_spool()),
                          "suppress_pending": load_json("suppress_pending.json", []),
                          "last_scan": load_json("last_scan.json", {})}, ensure_ascii=False, indent=1))
        return 0
    if cmd in ("run", "scan"):
        s = Scan(conf).run()
        if s.new_items or s.errors or s.missing:
            log("scan: %d new item(s), errors %s, missing %d" % (s.new_items, s.errors or "none", len(s.missing)))
    if cmd in ("run", "send"):
        try:
            sent, inserted = send(conf)
            if sent:
                log("sent %d item(s), %d new in %s" % (sent, inserted, conf["TARGET"]))
        except Exception as e:
            log("send failed, spool kept: %s" % e)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
