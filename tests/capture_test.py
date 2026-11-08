#!/usr/bin/env python3
"""Tests for scripts/capture.py on synthetic transcripts, without network or database.

    python3 -I tests/capture_test.py
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_capture(home):
    os.environ["MEMOHUB_CAPTURE_HOME"] = home
    spec = importlib.util.spec_from_file_location("capture", os.path.join(ROOT, "scripts", "capture.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def cc(kind, text=None, sid="s1", uuid=None, **extra):
    rec = {"type": kind, "sessionId": sid, "uuid": uuid or ("u-" + str(abs(hash((kind, text))) % 10**8)),
           "timestamp": "2026-11-08T10:00:00Z", "cwd": "/Users/x/Projects/memohub", "isSidechain": False}
    if text is not None:
        rec["message"] = {"role": kind, "content": text}
    rec.update(extra)
    return json.dumps(rec, ensure_ascii=False) + "\n"


class CaptureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="capture-test-")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.claude = os.path.join(self.tmp, "claude")
        self.codex = os.path.join(self.tmp, "codex")
        self.meet = os.path.join(self.tmp, "meet")
        for d in (os.path.join(self.claude, "-Users-x-Projects-memohub"), self.codex, self.meet):
            os.makedirs(d)
        self.fake_log = os.path.join(self.tmp, "sent.jsonl")
        os.environ["FAKE_LOG"] = self.fake_log
        os.environ["MEMOHUB_CAPTURE_SENDER"] = "%s %s" % (sys.executable, os.path.join(ROOT, "tests", "fake_capture_sender.py"))
        self.conf({})

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def conf(self, extra):
        c = {"DEVICE": "test-mac", "TARGET": "private", "MODE": "all", "CLAUDE_DIR": self.claude,
             "CODEX_DIR": self.codex, "MEETINGS_DIR": self.meet}
        c.update(extra)
        with open(os.path.join(self.home, "capture.conf"), "w") as f:
            f.write("".join("%s=%s\n" % kv for kv in c.items()))

    def run_capture(self, cmd="run"):
        mod = load_capture(self.home)
        sys.argv = ["capture.py", cmd]
        return mod, mod.main()

    def sent(self):
        if not os.path.exists(self.fake_log):
            return []
        return [json.loads(l) for l in open(self.fake_log, encoding="utf-8")]

    def sent_items(self):
        return [it for p in self.sent() for it in p.get("items", [])]

    def session(self, name="s1.jsonl"):
        return os.path.join(self.claude, "-Users-x-Projects-memohub", name)

    def write(self, path, text, mode="a"):
        with open(path, mode, encoding="utf-8") as f:
            f.write(text)

    # ------------------------------------------------------------------

    def test_mask_cases_match_sql(self):
        mod = load_capture(self.home)
        for c in json.loads(open(os.path.join(ROOT, "tests", "mask_cases.json"), encoding="utf-8").read()
                            .replace("{{HEX40}}", "0123456789abcdef" * 2 + "01234567")):
            self.assertEqual(mod.mask(c["in"]), (c["out"], c["kinds"]), c["name"])

    def test_claude_text_only_masked_and_acked(self):
        p = self.session()
        self.write(p, cc("user", "Как устроен журнал? ключ sk-abcdefghijklmnopqrstuvwxyz1234", uuid="a1"))
        self.write(p, cc("assistant", [{"type": "thinking", "thinking": "hmm"}], uuid="a2"))
        self.write(p, cc("assistant", [{"type": "tool_use", "name": "Bash"}], uuid="a3"))
        self.write(p, cc("user", [{"type": "tool_result", "content": "out"}], uuid="a4", toolUseResult={}))
        self.write(p, cc("assistant", [{"type": "text", "text": "Реплики идут в captures"}], uuid="a5"))
        self.write(p, cc("user", "meta", uuid="a6", isMeta=True))
        self.write(p, cc("user", "sub", uuid="a7", isSidechain=True))
        self.write(p, cc("user", "summary", uuid="a8", isCompactSummary=True))
        self.write(p, cc("user", "<task-notification>x</task-notification>", uuid="a9"))
        mod, rc = self.run_capture()
        self.assertEqual(rc, 0)
        items = self.sent_items()
        self.assertEqual([i["key"] for i in items], ["cc-s1:a1", "cc-s1:a5"])
        self.assertIn("[masked:credential]", items[0]["content"])
        self.assertNotIn("sk-abc", open(os.path.join(self.home, "capture", "spool.jsonl")).read())
        self.assertEqual(items[0]["project_hint"], "memohub")
        self.assertEqual(mod.read_spool(), {})
        # Nothing new: no second call within the hour.
        self.run_capture()
        self.assertEqual(len(self.sent()), 1)

    def test_partial_line_waits(self):
        p = self.session()
        line = cc("user", "первая", uuid="b1")
        self.write(p, line + line.replace("b1", "b2").replace("первая", "вторая")[:-20])
        self.run_capture()
        self.assertEqual([i["key"] for i in self.sent_items()], ["cc-s1:b1"])
        self.write(p, line.replace("b1", "b2").replace("первая", "вторая")[-20:])
        self.run_capture()
        self.assertEqual([i["key"] for i in self.sent_items()], ["cc-s1:b1", "cc-s1:b2"])

    def test_send_failure_keeps_spool(self):
        self.write(self.session(), cc("user", "важное", uuid="c1"))
        open(self.fake_log + ".fail", "w").close()
        mod, rc = self.run_capture()
        self.assertEqual(rc, 1)
        self.assertIn("cc-s1:c1", mod.read_spool())
        os.unlink(self.fake_log + ".fail")
        mod, rc = self.run_capture()
        self.assertEqual(rc, 0)
        self.assertEqual(mod.read_spool(), {})

    def test_nomemo_before_sending(self):
        p = self.session()
        self.write(p, cc("user", "обычное начало", uuid="d1"))
        self.write(p, cc("assistant", [{"type": "text", "text": "ответ"}], uuid="d2"))
        self.write(p, cc("user", "дальше личное #nomemo", uuid="d3"))
        self.run_capture()
        payloads = self.sent()
        self.assertEqual(self.sent_items(), [])
        self.assertEqual(payloads[0]["suppress"], ["cc-s1"])
        # Later messages of the chat are not sent either.
        self.write(p, cc("user", "ещё", uuid="d4"))
        self.run_capture()
        self.assertEqual(self.sent_items(), [])

    def test_nomemo_late_deletes_and_assistant_tag_ignored(self):
        p = self.session()
        self.write(p, cc("user", "начало", uuid="e1"))
        self.write(p, cc("assistant", [{"type": "text", "text": "напишите #nomemo, если не надо"}], uuid="e2"))
        self.run_capture()
        self.assertEqual([i["key"] for i in self.sent_items()], ["cc-s1:e1", "cc-s1:e2"])
        self.write(p, cc("user", "#nomemo", uuid="e3"))
        self.run_capture()
        self.assertEqual(self.sent()[-1]["suppress"], ["cc-s1"])
        self.assertEqual(len(self.sent_items()), 2)

    def test_projects_mode(self):
        self.conf({"MODE": "projects", "PROJECTS": "agent_platform", "TARGET": "shared"})
        listed = os.path.join(self.claude, "-Users-x-Projects-agent_platform")
        os.makedirs(listed)
        self.write(os.path.join(listed, "w1.jsonl"),
                   cc("user", "рабочее", sid="w1", uuid="f1", cwd="/Users/x/Projects/agent_platform"))
        self.write(self.session("w2.jsonl"), cc("user", "личное в другом проекте", sid="w2", uuid="f2"))
        self.write(self.session("w3.jsonl"), cc("user", "#memo разовый чат", sid="w3", uuid="f3"))
        self.write(self.session("w4.jsonl"), cc("user", "сначала без тега", sid="w4", uuid="f4")
                   + cc("user", "#memo поздно", sid="w4", uuid="f5"))
        self.run_capture()
        self.assertEqual(sorted(i["chat_ref"] for i in self.sent_items()), ["cc-w1", "cc-w3"])

    def test_codex(self):
        d = os.path.join(self.codex, "2026", "11", "08")
        os.makedirs(d)
        recs = [
            {"type": "session_meta", "payload": {"id": "x9", "cwd": "/Users/x/Projects/memohub"}},
            {"type": "response_item", "timestamp": "2026-11-08T11:00:00Z",
             "payload": {"type": "message", "role": "user", "id": "m0",
                         "content": [{"type": "input_text", "text": "<environment_context>cwd</environment_context>"}]}},
            {"type": "response_item", "timestamp": "2026-11-08T11:00:01Z",
             "payload": {"type": "message", "role": "user", "id": "m1",
                         "content": [{"type": "input_text", "text": "Проверь миграцию"}]}},
            {"type": "response_item", "timestamp": "2026-11-08T11:00:02Z",
             "payload": {"type": "message", "role": "assistant", "id": "m2",
                         "content": [{"type": "output_text", "text": "Ошибок нет"}]}},
            {"type": "event_msg", "payload": {"type": "task_complete"}},
        ]
        self.write(os.path.join(d, "rollout-x9.jsonl"), "".join(json.dumps(r) + "\n" for r in recs))
        self.run_capture()
        self.assertEqual([(i["key"], i["role"]) for i in self.sent_items()],
                         [("codex-x9:m1", "user"), ("codex-x9:m2", "assistant")])

    def test_meeting_settles_then_chunks(self):
        p = os.path.join(self.meet, "2026-11-08_10-00.txt")
        self.write(p, "[00:00] Обсуждаем журнал\n" * 10)
        os.makedirs(os.path.join(self.meet, "2026-11-08_10-00-slides"))
        self.write(os.path.join(self.meet, "2026-11-08_10-00-slides", "slides.json"),
                   json.dumps([{"index": 1, "text": "Архитектура"}]))
        self.run_capture()
        self.assertEqual(self.sent_items(), [])            # too fresh
        old = time.time() - 3600
        os.utime(p, (old, old))
        self.run_capture()
        items = self.sent_items()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["chat_ref"], "meeting-2026-11-08_10-00")
        self.assertIn("Slide 1: Архитектура", items[0]["content"])

    def test_long_message_chunks_and_restart(self):
        p = self.session()
        self.write(p, cc("user", "я" * 120000, uuid="g1"))
        mod, _ = self.run_capture()
        items = self.sent_items()
        self.assertEqual([(i["key"], i["part"], len(i["content"])) for i in items],
                         [("cc-s1:g1", 0, 50000), ("cc-s1:g1#1", 1, 50000), ("cc-s1:g1#2", 2, 20000)])
        # The file is replaced by a shorter one: re-read from the start, keys stay the same.
        os.unlink(p)
        self.write(p, cc("user", "новое", uuid="g2"), "w")
        self.run_capture()
        self.assertEqual(self.sent_items()[-1]["key"], "cc-s1:g2")

    def test_continued_session_keeps_chats_apart(self):
        # A continued session's file starts with the parent's records under the parent's id.
        p = self.session("child.jsonl")
        self.write(p, cc("user", "родительский чат", sid="parent", uuid="h1"))
        self.write(p, cc("assistant", [{"type": "text", "text": "ответ родителю"}], sid="parent", uuid="h2"))
        self.write(p, cc("user", "продолжение #nomemo", sid="child", uuid="h3"))
        self.run_capture()
        self.assertEqual([(i["chat_ref"], i["key"]) for i in self.sent_items()],
                         [("cc-parent", "cc-parent:h1"), ("cc-parent", "cc-parent:h2")])
        self.assertEqual(self.sent()[0]["suppress"], ["cc-child"])
        # The parent's own file repeats the same records: same keys, nothing new.
        self.write(self.session("parent.jsonl"), cc("user", "родительский чат", sid="parent", uuid="h1"))
        self.run_capture()
        self.assertEqual(sorted({i["key"] for i in self.sent_items()}), ["cc-parent:h1", "cc-parent:h2"])

    def test_suppressed_chat_stays_suppressed_after_file_replaced(self):
        p = self.session()
        self.write(p, cc("user", "начало", uuid="i1") + cc("user", "#nomemo", uuid="i2"))
        self.run_capture()
        os.unlink(p)
        self.write(p, cc("user", "начало", uuid="i1") + cc("user", "новое", uuid="i3"), "w")
        self.run_capture()
        self.assertEqual(self.sent_items(), [])

    def test_tags_in_pasted_text_or_output_do_not_count(self):
        p = self.session()
        self.write(p, cc("user", '<pasted_content id="1">план: eval, #nomemo, маскировка</pasted_content> что думаешь?', uuid="j1"))
        self.write(p, cc("user", "<bash-input>grep nomemo</bash-input><bash-stdout>#nomemo found</bash-stdout>", uuid="j2"))
        self.run_capture()
        self.assertEqual([i["key"] for i in self.sent_items()], ["cc-s1:j1", "cc-s1:j2"])
        self.assertEqual(self.sent()[0].get("suppress"), [])

    def test_unreadable_meetings_dir_does_not_stop_other_sources(self):
        self.conf({"MEETINGS_DIR": os.path.join(self.tmp, "locked")})
        os.makedirs(os.path.join(self.tmp, "locked"))
        os.chmod(os.path.join(self.tmp, "locked"), 0)
        self.write(self.session(), cc("user", "чат идёт", uuid="k1"))
        try:
            _, rc = self.run_capture()
        finally:
            os.chmod(os.path.join(self.tmp, "locked"), 0o700)
        self.assertEqual(rc, 0)
        self.assertEqual([i["key"] for i in self.sent_items()], ["cc-s1:k1"])
        status = {s["source"]: s for s in self.sent()[0]["sources"]}
        self.assertIn("Permission denied", status["meeting"]["error"])
        self.assertIsNone(status["claude-code"]["error"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
