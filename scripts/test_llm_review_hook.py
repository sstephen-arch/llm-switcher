"""Tests for llm-review-hook.py's decisions. Run: /usr/bin/python3 -m unittest scripts/test_llm_review_hook.py"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "llm-review-hook.py")
spec = importlib.util.spec_from_file_location("llm_review_hook", HOOK)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


def run_hook(env_url, payload, extra_env=None):
    env = dict(os.environ, ANTHROPIC_BASE_URL=env_url, **(extra_env or {}))
    p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True, text=True, env=env, timeout=30)
    return p.returncode, p.stdout


class CloudSessions(unittest.TestCase):
    def test_cloud_session_is_never_reviewed(self):
        code, out = run_hook("https://api.anthropic.com", {"session_id": "t", "cwd": HERE})
        self.assertEqual((code, out), (0, ""))

    def test_off_switch(self):
        code, out = run_hook("http://127.0.0.1:11436", {"session_id": "t", "cwd": HERE}, {"LLM_REVIEW": "off"})
        self.assertEqual((code, out), (0, ""))


class TaskFinder(unittest.TestCase):
    """The task must stay the person's request, or the 3-round cap resets every round."""

    def transcript(self, entries):
        f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        for e in entries:
            f.write(json.dumps(e) + "\n")
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_ignores_hook_feedback_meta_entries_and_tool_results(self):
        path = self.transcript([
            {"type": "user", "message": {"content": "Add a median function"}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}},
            {"type": "user", "isMeta": True, "message": {"content": "caveat"}},
            {"type": "user", "message": {"content": "Stop hook feedback:\nAn independent reviewer (gpt-oss) checked ..."}},
            {"type": "user", "message": {"content": "An independent reviewer (gpt-oss, high reasoning) checked ..."}},
            {"type": "user", "message": {"content": "<system-reminder>x</system-reminder>"}},
        ])
        self.assertEqual(hook.last_user_prompt(path), "Add a median function")

    def test_a_new_request_replaces_the_old_one(self):
        path = self.transcript([
            {"type": "user", "message": {"content": "First task"}},
            {"type": "user", "message": {"content": [{"type": "text", "text": "Second task"}]}},
        ])
        self.assertEqual(hook.last_user_prompt(path), "Second task")


class CleanReview(unittest.TestCase):
    def test_short_no_issues_is_clean(self):
        self.assertTrue(hook.is_clean("NO ISSUES", ""))

    def test_long_review_mentioning_no_issues_is_not_clean(self):
        text = "There are no issues with parsing, but the cache never expires. " + "Details. " * 60
        self.assertFalse(hook.is_clean(text, ""))

    def test_failing_tests_are_never_clean(self):
        self.assertFalse(hook.is_clean("NO ISSUES", "Running `swift test` failed"))


if __name__ == "__main__":
    unittest.main()
