#!/usr/bin/env python3
"""Stand-in for memohub.capture_batch in tests/capture_test.py: logs payloads, acks every key."""
import json
import os
import sys

payload = json.load(sys.stdin)
with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, ensure_ascii=False) + "\n")
if os.path.exists(os.environ["FAKE_LOG"] + ".fail"):
    sys.exit("simulated failure")
keys = [it["key"] for it in payload.get("items", [])]
print(json.dumps({"ok": True, "inserted": len(keys), "duplicates": 0, "suppressed": 0,
                  "acked": keys, "rejected": [], "suppressed_chats": payload.get("suppress", [])}))
