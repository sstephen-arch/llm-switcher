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
        self.assertEqual(hook.read_transcript(path)["prompt"], "Add a median function")

    def test_a_new_request_replaces_the_old_one(self):
        path = self.transcript([
            {"type": "user", "message": {"content": "First task"}},
            {"type": "user", "message": {"content": [{"type": "text", "text": "Second task"}]}},
        ])
        self.assertEqual(hook.read_transcript(path)["prompt"], "Second task")


class CleanReview(unittest.TestCase):
    def test_short_no_issues_is_clean(self):
        self.assertTrue(hook.is_clean("NO ISSUES", ""))

    def test_long_review_mentioning_no_issues_is_not_clean(self):
        text = "There are no issues with parsing, but the cache never expires. " + "Details. " * 60
        self.assertFalse(hook.is_clean(text, ""))

    def test_failing_tests_are_never_clean(self):
        self.assertFalse(hook.is_clean("NO ISSUES", "Running `swift test` failed"))


class LightReviewTests(unittest.TestCase):
    def transcript(self, entries):
        f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        for e in entries:
            f.write(json.dumps(e) + "\n")
        f.close()
        return f.name

    def test_no_review_when_the_request_edited_nothing(self):
        t = self.transcript([
            {"type": "user", "message": {"content": "fix the bug"}},
            {"type": "assistant", "message": {"model": "claude-sonnet-5", "content": [{"type": "tool_use", "name": "Edit", "input": {}}]}},
            {"type": "user", "message": {"content": "hi"}},
            {"type": "assistant", "message": {"model": "claude-sonnet-5", "content": [{"type": "text", "text": "hello"}]}},
        ])
        self.assertFalse(hook.read_transcript(t)["edited"], "the 'hi' request changed nothing")

    def test_review_when_the_request_edited_files(self):
        t = self.transcript([
            {"type": "user", "message": {"content": "add a test"}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {}}]}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Write", "input": {}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}},
        ])
        self.assertTrue(hook.read_transcript(t)["edited"], "a tool result is not a new request")

    def test_reviewer_is_the_sessions_own_model(self):
        t = self.transcript([
            {"type": "assistant", "message": {"model": "claude-fable-5", "content": []}},
            {"type": "assistant", "message": {"model": "claude-sonnet-5", "content": []}},
        ])
        self.assertEqual(hook.read_transcript(t)["model"], "claude-sonnet-5")
        self.assertEqual(hook.read_transcript("/nonexistent")["model"], "")


class ShellEditTests(unittest.TestCase):
    def test_shell_commands_that_write_count_as_edits(self):
        writes = ["sed -i '' 's/a/b/' f.py", "cat > f.py <<'EOF'", "echo x >> log.txt", "git apply p.diff",
                  "mv a b", "rm -f old.py", "python3 gen.py | tee out.txt", "git checkout -- f.py", "perl -pi -e 's/a/b/' f"]
        reads = ["ls -la", "git status", "git diff HEAD", "grep -rn foo .", "make test 2>&1 | tail", "cat f.py",
                 "swift build > /dev/null", "echo hi 2>&1", "git log --oneline"]
        for c in writes:
            self.assertTrue(hook._edits({"type": "tool_use", "name": "Bash", "input": {"command": c}}), c)
        for c in reads:
            self.assertFalse(hook._edits({"type": "tool_use", "name": "Bash", "input": {"command": c}}), c)


class CommitTriggerTests(unittest.TestCase):
    def test_finds_commits_and_their_folder(self):
        cwd = "/work/app"
        self.assertEqual(hook.commit_dir("git commit -m 'x'", cwd), "/work/app")
        self.assertEqual(hook.commit_dir("git add -A && git commit -q -F - <<'EOF'", cwd), "/work/app")
        self.assertEqual(hook.commit_dir("cd ~/Developer/x && git add . && git commit -m y", cwd), os.path.expanduser("~/Developer/x"))
        self.assertEqual(hook.commit_dir("cd sub && git commit -am fix", cwd), "/work/app/sub")
        self.assertEqual(hook.commit_dir("git -C /repo/other commit -m z", cwd), "/repo/other")
        for not_commit in ["git status", "git commit-tree abc -m x", "git log --grep commit", "echo commit", "git diff"]:
            self.assertIsNone(hook.commit_dir(not_commit, cwd), not_commit)

    def test_normal_turns_and_other_commands_are_left_alone(self):
        local = "http://127.0.0.1:11436"
        repo = tempfile.mkdtemp()
        subprocess.run(["git", "init", "-q", repo])
        open(os.path.join(repo, "a.py"), "w").write("x = 1\n")
        for payload in [
            {"hook_event_name": "Stop", "session_id": "s1", "cwd": repo, "transcript_path": "/nonexistent"},
            {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "git status"}, "session_id": "s1", "cwd": repo},
            {"hook_event_name": "PreToolUse", "tool_name": "Write", "tool_input": {}, "session_id": "s1", "cwd": repo},
        ]:
            self.assertEqual(run_hook(local, payload)[1].strip(), "", payload["hook_event_name"])




class CommitSafetyTests(unittest.TestCase):
    def test_commit_outside_the_session_folder_is_not_reviewed(self):
        outside = tempfile.mkdtemp()
        subprocess.run(["git", "init", "-q", outside])
        # A repo whose test command would leave a marker if it ever ran.
        marker = os.path.join(outside, "ran")
        json.dump({"test": "touch %s" % marker, "reviewer": "nobody"}, open(os.path.join(outside, ".llm-review.json"), "w"))
        open(os.path.join(outside, "x.py"), "w").write("x = 1\n")
        session = tempfile.mkdtemp()
        payload = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s2", "cwd": session,
                   "tool_input": {"command": "cd %s && git add -A && git commit -m x" % outside}}
        code, out = run_hook("http://127.0.0.1:11436", payload)
        self.assertEqual((code, out.strip()), (0, ""))
        self.assertFalse(os.path.exists(marker), "a test command from another repo must never run")


if __name__ == "__main__":
    unittest.main()
