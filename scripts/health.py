#!/usr/bin/env python3
"""memohub completeness and health report (A3).

    health.py                 print the report (Markdown) for the last 7 days
    health.py --days 30       another period
    health.py --notify        also save it to ~/.memohub/reports/ and show a macOS notification
                              when something needs attention (used by the weekly launchd job)

Combines memohub.health() from each database (capture sources, notes saved, size) with what only
this Mac knows: the capture scanner's spool and errors, the latest backups, launchd jobs and
how long Claude Code keeps its transcripts. Databases: TARGETS from ~/.memohub/backup.conf
(default: shared), queried as the owner through the linked Supabase CLI.
"""

import glob
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser(os.environ.get("MEMOHUB_CAPTURE_HOME", "~/.memohub"))
NO_GUARANTEE = [
    ("Claude on the phone and claude.ai (personal)", "only \"tomemo\"; export postponed"),
    ("Claude, company account", "only \"tomemo\"; no export"),
    ("ChatGPT", "only \"tomemo\"; export postponed"),
]


def conf(path):
    out = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def query(target, sql):
    wd = REPO if target == "shared" else os.path.join(REPO, "targets", "private")
    out = subprocess.run(["supabase", "--workdir", wd, "db", "query", "--linked", "--output-format", "json", sql],
                         capture_output=True, text=True, timeout=300)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[-200:] or "supabase CLI failed")
    m = re.search(r"^[\[{]", out.stdout, re.M)
    if not m:
        raise RuntimeError("no JSON in CLI output")
    data = json.loads(out.stdout[m.start():])
    rows = data["rows"] if isinstance(data, dict) else data
    v = list(rows[0].values())[0]
    return json.loads(v) if isinstance(v, str) else v


def parse_ts(value):
    """Postgres timestamps as datetimes. Python 3.9 (the system python3 that launchd runs)
    accepts only 3 or 6 fraction digits, and Postgres drops trailing zeros (.92)."""
    m = re.match(r"^(.*?)(?:\.(\d+))?(Z|[+-]\d\d(?::?\d\d)?)?$", value.strip())
    zone = (m.group(3) or "+00:00").replace("Z", "+00:00")
    zone = zone[:3] + ":" + (zone[3:].lstrip(":") or "00")
    return datetime.fromisoformat("%s.%s%s" % (m.group(1), (m.group(2) or "0").ljust(6, "0")[:6], zone))


def ago(ts):
    if not ts:
        return "never"
    t = parse_ts(ts)
    h = (datetime.now(timezone.utc) - t).total_seconds() / 3600
    if h < 1:
        return "just now"
    if h < 48:
        return "%d h ago" % h
    return "%d d ago" % (h / 24)


def hours_since(ts):
    if not ts:
        return None
    t = parse_ts(ts)
    return (datetime.now(timezone.utc) - t).total_seconds() / 3600


def mb(n):
    return "%.1f MB" % (n / 1e6)


def launchd_loaded(label):
    r = subprocess.run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), label)], capture_output=True, text=True)
    return r.returncode == 0


def local_state(days):
    st = os.path.join(HOME, "capture")
    spool = 0
    if os.path.exists(os.path.join(st, "spool.jsonl")):
        spool = sum(1 for l in open(os.path.join(st, "spool.jsonl"), encoding="utf-8") if l.strip())
    try:
        last = json.load(open(os.path.join(st, "last_scan.json"), encoding="utf-8"))
    except (OSError, ValueError):
        last = {}
    rejected = 0
    if os.path.exists(os.path.join(st, "rejected.jsonl")):
        rejected = sum(1 for _ in open(os.path.join(st, "rejected.jsonl"), encoding="utf-8"))
    since = time.time() - days * 86400
    failures = []
    logp = os.path.join(HOME, "capture.log")
    if os.path.exists(logp):
        for line in open(logp, encoding="utf-8", errors="replace"):
            if "send failed" in line or line[20:].startswith("error"):
                try:
                    t = time.mktime(time.strptime(line[:19], "%Y-%m-%d %H:%M:%S"))
                except ValueError:
                    continue
                if t >= since:
                    failures.append(line.strip())
    return {"spool": spool, "last_scan": last, "rejected": rejected, "failures": failures}


def backups(targets):
    out = {}
    for t in targets:
        files = sorted(glob.glob(os.path.join(HOME, "backups", t, "memohub-*.json.gz.age")))
        out[t] = (os.path.getmtime(files[-1]), os.path.getsize(files[-1])) if files else None
    return out


def claude_retention():
    days = 30
    try:
        days = int(json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("cleanupPeriodDays", 30))
    except (OSError, ValueError, TypeError):
        pass
    files = glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
    oldest = min((os.path.getmtime(f) for f in files), default=None)
    return days, oldest


def build(days):
    bconf = conf(os.path.join(HOME, "backup.conf"))
    cconf = conf(os.path.join(HOME, "capture.conf"))
    targets = (bconf.get("TARGETS") or "shared").split()
    device = cconf.get("DEVICE")
    problems, lines = [], []
    now = datetime.now().strftime("%d.%m.%Y %H:%M")
    lines.append("# memohub: completeness and health, %s" % now)
    lines.append("")
    lines.append("Period: %d d. Mac: %s." % (days, device or "journal scanner not configured"))

    for t in targets:
        lines.append("")
        lines.append("## Database %s" % t)
        try:
            h = query(t, "select memohub.health(%d) as h" % days)
        except Exception as e:
            problems.append("%s: database did not answer (%s)" % (t, e))
            lines.append("Did not answer: %s" % e)
            continue
        n = h["notes"]
        lines.append("")
        lines.append("- Notes: %d active, %d saved in the period, latest %s." %
                     (n["active"], n["saved_recently"], ago(n["last_saved_at"])))
        if n["by_source"]:
            lines.append("- Saved by: " + ", ".join("%s %d" % kv for kv in sorted(n["by_source"].items())) + ".")
        if n["without_embedding"]:
            lines.append("- Without embeddings: %d (the daily backup fills them in)." % n["without_embedding"])
        j = h["journal"]
        lines.append("- Journal: %d messages, %d chats, %s; excluded and forgotten chats: %d." %
                     (j["captures"], j["chats"], mb(j["bytes"]), j["suppressed_chats"]))
        used, limit = h["database_bytes"], h["database_limit_bytes"]
        lines.append("- Database size: %s of %s (%d%%)." % (mb(used), mb(limit), 100 * used / limit))
        if used > 0.8 * limit:
            problems.append("%s: database is %d%% full" % (t, 100 * used / limit))
        if h["capture_sources"]:
            lines.append("")
            lines.append("| Source | Device | Messages (period) | Last scan | Last message | Error |")
            lines.append("|---|---|---|---|---|---|")
            for s in h["capture_sources"]:
                lines.append("| %s | %s | %d (%d) | %s | %s | %s |" % (
                    s["source"], s["device"], s["captures"], s["recent"],
                    "—" if s["source"] == "shortcut" else ago(s["last_scan_at"]),
                    ago(s["last_capture_at"]), s.get("error") or "—"))
                if s.get("error"):
                    problems.append("%s/%s: %s" % (s["source"], s["device"], s["error"]))
                if s["source"] != "shortcut" and s["device"] == device and (s.get("quiet_hours") or 0) > 24:
                    problems.append("%s on %s not scanned for %d h" % (s["source"], device, s["quiet_hours"]))
        d = h.get("distill") or {}
        if d.get("enabled") or d.get("last_run"):
            r = d.get("last_run") or {}
            lines.append("- Distiller: %s; last run %s (%s, %d chats, %d candidates); waiting for review: %d; "
                         "list price in 30 d: $%.2f." % (
                             "paused" if d.get("paused") else "on" if d.get("enabled") else "off",
                             ago(r.get("started_at")), r.get("status", "none"), r.get("chats") or 0,
                             r.get("candidates") or 0, d.get("proposed") or 0, float(d.get("cost_30d_usd") or 0)))
            if d.get("paused"):
                problems.append("%s: distiller paused after 3 failed runs (last error: %s); scripts/distill.py resume"
                                % (t, r.get("error")))
            if d.get("failed_chats"):
                problems.append("%s: %d chats failed to distill 3 times (scripts/distill.py resume --retry-failed)" % (t, d["failed_chats"]))
            if d.get("enabled") and not launchd_loaded("com.memohub.distill"):
                problems.append("distiller is on but its job is not loaded (scripts/install-distill.sh)")
        for k in h.get("device_keys", []):
            if k.get("last_used_at") is None:
                lines.append("- Device key %s has not been used yet." % k["device"])

    if device:
        loc = local_state(days)
        lines.append("")
        lines.append("## Journal scanner on this Mac")
        lines.append("")
        lines.append("- launchd job: %s; last scan %s." % (
            "running" if launchd_loaded("com.memohub.capture") else "NOT loaded", ago(loc["last_scan"].get("at"))))
        if not launchd_loaded("com.memohub.capture"):
            problems.append("journal scanner job not loaded (scripts/install-capture.sh)")
        lines.append("- Waiting to send: %d; rejected by the database in total: %d." % (loc["spool"], loc["rejected"]))
        if loc["spool"] and loc["failures"]:
            problems.append("journal queue is stuck: %d messages waiting, last error: %s" %
                            (loc["spool"], loc["failures"][-1][20:120]))
        missing = loc["last_scan"].get("missing") or []
        if missing:
            problems.append("%d transcript files disappeared before sending" % len(missing))
        if loc["failures"]:
            lines.append("- Errors in the period: %d, latest: `%s`." % (len(loc["failures"]), loc["failures"][-1][:160]))
        days_kept, oldest = claude_retention()
        lines.append("- Claude Code keeps transcripts for %d d; the oldest is %s." % (
            days_kept, "%d d old" % ((time.time() - oldest) / 86400) if oldest else "none"))

    lines.append("")
    lines.append("## Backups")
    lines.append("")
    lines.append("- launchd job: %s." % ("running" if launchd_loaded("com.memohub.backup") else "NOT loaded"))
    for t, b in backups(targets).items():
        if not b:
            lines.append("- %s: no copies on this Mac." % t)
            problems.append("%s: no backups on this Mac" % t)
            continue
        age_h = (time.time() - b[0]) / 3600
        lines.append("- %s: latest %s, %s." % (t, ago(datetime.fromtimestamp(b[0], timezone.utc).isoformat()), mb(b[1])))
        if age_h > 36:
            problems.append("%s: latest backup %d h ago" % (t, age_h))

    lines.append("")
    lines.append("## No completeness guarantee")
    lines.append("")
    for name, how in NO_GUARANTEE:
        lines.append("- %s — %s." % (name, how))

    head = ["", "## Needs attention", ""] + (["- " + p for p in problems] if problems else ["- Nothing."])
    lines[3:3] = head
    return "\n".join(lines) + "\n", problems


def main():
    days = 7
    if "--days" in sys.argv:
        days = int(sys.argv[sys.argv.index("--days") + 1])
    report, problems = build(days)
    print(report)
    if "--notify" in sys.argv:
        d = os.path.join(HOME, "reports")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "health-%s.md" % datetime.now().strftime("%Y-%m-%d"))
        with open(path, "w", encoding="utf-8") as f:
            f.write(report)
        if problems:
            msg = "%d: %s" % (len(problems), problems[0])
            msg = msg.replace("\\", "").replace('"', "'")[:200]
            subprocess.run(["osascript", "-e", 'display notification "%s" with title "memohub" subtitle "Report: %s"'
                            % (msg, os.path.basename(path))], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
