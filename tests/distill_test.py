#!/usr/bin/env python3
"""Unit checks for scripts/distill.py that need no database or model. CI runs them on the
oldest Python the Mac jobs use (the system python3, 3.9)."""
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("distill", os.path.join(ROOT, "scripts", "distill.py"))
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)

# Postgres drops trailing zeros in fractions; Python 3.9 fromisoformat does not accept that.
for v in ("2026-09-27T09:03:06.92+00:00", "2026-11-09T12:56:23.746803+00:00", "2026-11-09 16:18:30+00",
          "2026-11-09T16:18:30Z", "2026-11-09T16:18:30.1+03:00"):
    assert d.ts(v).tzinfo is not None, v
assert d.ts("2026-09-27T09:03:06.92+00:00") < d.ts("2026-09-27T09:03:06.921+00:00")

catalog = {"work": {"agentic-platform": {"agentic-platform", "agent-platform"}},
           "personal": {"sud": {"sud", "суд"}}, "travel": {}}
assert d.project_of("agent_platform", catalog) == ("work", "agentic-platform")
assert d.project_of("Суд", catalog) == ("personal", "sud")
assert d.project_of("nothing", catalog) is None

msgs = [{"id": "a", "role": "user", "event_at": "2026-11-01T10:00:00.5+00:00", "content": "Старое " * 100},
        {"id": "b", "role": "user", "event_at": "2026-11-01T10:01:00+00:00", "content": "/tomemo"},
        {"id": "c", "role": "user", "event_at": "2026-11-01T10:02:00+00:00", "content": "Новое решение " * 50},
        {"id": "e", "role": "assistant", "event_at": "2026-11-01T10:03:00.12+00:00", "content": "Принято " * 50}]
tail, size, user = d.build_input({"messages": msgs, "saved_titles": ["Старая записка"]},
                                 {"source": "claude-code", "project_hint": "agent_platform"}, catalog, 200000)
assert [m["id"] for m in tail] == ["c", "e"] and "Старое" not in user and "[1] user: Новое" in user, user[:300]
assert "project agentic-platform in space work" in user and "- Старая записка" in user
assert max(d.ts(m["event_at"]) for m in tail) == d.ts("2026-11-01T10:03:00.12+00:00")

good = {"title": "Решение", "space": "work", "project": None, "body_md": "x", "decisions": ["a, потому что b"],
        "sources": [1, 2, 9], "confidence": 0.8}
mine = {"title": "Личное", "space": "personal", "body_md": "", "decisions": [], "sources": [2], "confidence": 0.9}
cands, dropped = d.to_candidates([good, dict(good, title="Слабое", confidence=0.3), mine], tail, catalog, "agent_platform")
assert dropped == 1 and len(cands) == 2, (dropped, cands)
assert cands[0]["payload"]["project"] == "agentic-platform" and cands[0]["capture_ids"] == ["c", "e"]
assert "project" not in cands[1]["payload"]  # another space keeps no project
cands, dropped = d.to_candidates([dict(good, space="nope"), dict(good, sources=[]), dict(good, title=" ")],
                                 tail, catalog, None)
assert dropped == 3 and not cands, cands
print("DISTILL OK (python %d.%d)" % sys.version_info[:2])
