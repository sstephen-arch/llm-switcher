#!/usr/bin/env python3
"""LLM Switcher review hook for Claude Code.

When a LOCAL Claude Code session (one talking to LLM Switcher on 127.0.0.1:11436) is about to run a
`git commit` (PreToolUse on Bash), this reviews the repo's uncommitted changes adversarially,
and, if there are problems, holds the commit back and hands the
findings to Claude to fix; the next commit attempt goes through (one review per request by default),
so a review never blocks a commit for good. Normal conversation is never reviewed. Because this runs
before the person approves the command, it only reviews repos inside the session's own folder and
never runs a repo's "test" command (tests run only in "when": "stop" mode). Light by default:
the session's own model reviews (already loaded), at medium thinking. Cloud sessions are never touched.

Off switches: LLM_REVIEW=off in the environment, the toggle in LLM Switcher's Review loop tab, or a
.llm-review.json in the repo with {"enabled": false}.

Per-repo settings, .llm-review.json at the repo root (all optional):
  {"test": "swift test", "test_timeout": 600, "reviewer": "Qwen3.8-Flash-Next-oQ4e-mtp",
   "effort": "high", "max_rounds": 3, "enabled": true, "when": "commit", "review_all": false}
Defaults: reviewer = the session's model, effort "medium", max_rounds 1, when "commit".
"when": "stop" brings back the older review after every turn that edited files (review_all: true
reviews every turn with uncommitted changes). Registered for both PreToolUse (matcher Bash) and Stop.

Runs on the macOS system Python (3.9), standard library only.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request

GATEWAY = "http://127.0.0.1:11436"
STATE_DIR = os.path.expanduser("~/.claude/llm-switcher-review")
BUNDLE = "com.depaloconsulting.claudelocal"
MAX_DIFF = 60000
HOOK_BUDGET = 1700        # seconds; settings.json gives the hook 1800, keep a margin


def run(cmd, cwd, timeout=60):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout


def app_default(key, fallback):
    try:
        code, out = run(["defaults", "read", BUNDLE, key], cwd="/", timeout=5)
        return out.strip() if code == 0 and out.strip() else fallback
    except Exception:
        return fallback


def emit(obj):
    print(json.dumps(obj))
    return 0


# This hook's own messages, old wording included, so they're never mistaken for the person's request.
FEEDBACK_PREFIXES = ("Stop hook feedback", "An independent reviewer (", "A reviewer (")


def is_person(text):
    """Text the person typed, not tool output, a system tag or this hook's own feedback."""
    t = text.lstrip()
    return bool(t) and not t.startswith("<") and not t.startswith(FEEDBACK_PREFIXES) and not any(f in t[:300] for f in FEEDBACK_PREFIXES[1:])


def is_clean(review_text, failures):
    """A short review saying NO ISSUES and no failing tests. A long review that merely contains
    the words ("no issues with parsing, but ...") is not clean."""
    return "NO ISSUES" in review_text.upper() and len(review_text) < 400 and not failures


EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
# Shell commands that clearly change files: a redirect into a file (not 2>&1 or /dev/null), in-place
# edits, file moves/copies/removals, and git commands that rewrite the working tree.
SHELL_WRITE = re.compile(
    r"(?<![0-9&<>])>>?\s*(?!&|/dev/null)[^\s|;&]"
    r"|\bsed\s+(-[a-zA-Z]*\s+)*-i|\bperl\s+-[a-zA-Z]*i|\btee\b|\b(mv|cp|rm|touch|patch|truncate|unzip)\s"
    r"|\bgit\s+(apply|checkout|restore|reset|am|cherry-pick|revert|merge|rebase|stash\s+pop|mv|rm)\b")


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
    return ""


def _edits(item):
    if not isinstance(item, dict) or item.get("type") != "tool_use":
        return False
    if item.get("name") in EDIT_TOOLS:
        return True
    return item.get("name") == "Bash" and bool(SHELL_WRITE.search(str((item.get("input") or {}).get("command", ""))))


def read_transcript(transcript_path):
    """One pass over the session: the person's latest request (the task the changes are meant to do),
    whether files were changed since it (Edit/Write tools or a shell command that writes), and the model
    that answered. Without the "changed" check, a turn that edited nothing ("hi") would get a review of
    whatever was already uncommitted."""
    out = {"prompt": "", "edited": False, "model": ""}
    if not transcript_path or not os.path.exists(transcript_path):
        return out
    with open(transcript_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            msg = e.get("message") or {}
            content = msg.get("content")
            if e.get("type") == "user" and not e.get("isMeta"):
                text = _text(content)
                if is_person(text):
                    out["prompt"], out["edited"] = text.strip()[:6000], False     # a new request starts here
            elif e.get("type") == "assistant":
                out["model"] = msg.get("model") or out["model"]
                if isinstance(content, list) and any(_edits(c) for c in content):
                    out["edited"] = True
    return out


def changes(root):
    """Uncommitted changes: tracked edits plus new untracked files (contents included)."""
    code, diff = run(["git", "diff", "HEAD", "--no-color"], root)
    if code != 0:                       # no commits yet
        _, diff = run(["git", "diff", "--cached", "--no-color"], root)
        _, d2 = run(["git", "diff", "--no-color"], root)
        diff += d2
    _, untracked = run(["git", "ls-files", "--others", "--exclude-standard"], root)
    for path in untracked.splitlines()[:20]:
        full = os.path.join(root, path)
        try:
            if os.path.getsize(full) > 200_000:
                diff += "\n+++ new file %s (too large to include)\n" % path
                continue
            with open(full, encoding="utf-8") as f:
                body = f.read()
        except (OSError, UnicodeDecodeError):
            continue
        diff += "\n+++ new file %s\n%s\n" % (path, "\n".join("+" + l for l in body.splitlines()))
    return diff


def run_tests(cmd, root, timeout):
    try:
        p = subprocess.run(["/bin/zsh", "-lc", cmd], cwd=root, capture_output=True, text=True, timeout=timeout)
        out, status = (p.stdout + p.stderr), p.returncode
    except subprocess.TimeoutExpired:
        return False, 0.0, "tests stopped after %d s" % timeout, "timed out"
    passed = status == 0
    score = 1.0 if passed else 0.0
    m_pass = re.findall(r"(\d+) passed", out)
    m_fail = re.findall(r"(\d+) (?:failed|failures|error)", out)
    if m_pass:
        p_n, f_n = int(m_pass[-1]), int(m_fail[-1]) if m_fail else 0
        if p_n + f_n and not passed:
            score = p_n / (p_n + f_n)
    summary = "passed" if passed else "failed (exit %d)" % status
    return passed, score, out[-4000:], summary


def review(reviewer, effort, task, diff, failures, timeout=1100):
    tests = failures or "Any automated tests currently pass, but they are not exhaustive."
    prompt = (
        "Review these uncommitted code changes adversarially against the task. Hunt for bugs, unmet "
        "requirements, unhandled edge cases, security problems and performance problems.\n\n"
        "TASK (what the person asked for):\n%s\n\nCHANGES (git diff):\n```diff\n%s\n```\n\n%s\n\n"
        "For each real problem give: file and line, what is wrong, a concrete case that triggers it, "
        "and the fix. Be specific and concise; skip style and taste. If you find nothing wrong, "
        "reply exactly: NO ISSUES" % (task or "(not available)", diff, tests))
    # no temperature: the reviewer's tuned sampling comes from oMLX's per-model settings
    body = {"model": reviewer, "max_tokens": 32000 if effort == "high" else 16000,
            "reasoning_effort": effort, "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(GATEWAY + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.load(r)
    return (d["choices"][0]["message"].get("content") or "").strip()


COMMIT = re.compile(r"\bgit\s+(?:-[Cc]\s+(?:\"[^\"]*\"|'[^']*'|\S+)\s+)*commit(?![-\w])")
GIT_DIR = re.compile(r"\bgit\s+-C\s+(\"[^\"]*\"|'[^']*'|\S+)")
CD = re.compile(r"(?:^|&&|;|\|\|)\s*cd\s+(\"[^\"]*\"|'[^']*'|[^\s;&|]+)")


def commit_dir(command, cwd):
    """The folder a shell command commits in: `git -C <dir>`, else the last `cd <dir>` before the
    commit, else the session's folder. None when the command doesn't commit."""
    m = COMMIT.search(command or "")
    if not m:
        return None
    before = command[:m.end()]
    target = cwd
    for c in CD.finditer(before):
        target = os.path.join(target, os.path.expanduser(c.group(1).strip("\"'")))
    g = GIT_DIR.search(before[m.start():])
    if g:
        target = os.path.join(target, os.path.expanduser(g.group(1).strip("\"'")))
    return os.path.normpath(target)


def main():
    import time
    started = time.time()
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    if ":11436" not in os.environ.get("ANTHROPIC_BASE_URL", ""):
        return 0                                          # a cloud session: never review
    if os.environ.get("LLM_REVIEW", "").lower() in ("off", "0", "false", "no"):
        return 0
    if app_default("loop.autoReview", "1") in ("0", "false", "NO"):
        return 0
    cwd = data.get("cwd") or os.getcwd()
    # Reviews run when Claude is about to commit (PreToolUse on a `git commit`), not after every turn.
    # A repo can ask for the old after-every-turn review with "when": "stop" in .llm-review.json.
    event = data.get("hook_event_name") or "Stop"
    if event == "PreToolUse":
        if data.get("tool_name") != "Bash":
            return 0
        target = commit_dir((data.get("tool_input") or {}).get("command", ""), cwd)
        if not target:
            return 0                                      # not a commit
        # PreToolUse runs before the person approves the command, and the folder comes from the
        # command's text: only review inside the session's own folder, never a repo it names elsewhere.
        home = os.path.realpath(cwd)
        real = os.path.realpath(target)
        if real != home and not real.startswith(home + os.sep):
            return 0
        cwd = target
    elif event != "Stop":
        return 0
    try:
        code, root = run(["git", "rev-parse", "--show-toplevel"], cwd, timeout=10)
    except Exception:
        return 0
    if code != 0:
        return 0
    root = root.strip()
    cfg = {}
    try:
        with open(os.path.join(root, ".llm-review.json")) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        pass
    if cfg.get("enabled") is False:
        return 0
    at_commit = event == "PreToolUse"
    if at_commit != (cfg.get("when", "commit") != "stop"):
        return 0                                          # this repo reviews at the other moment
    tr = read_transcript(data.get("transcript_path"))
    # After-every-turn mode only: skip requests that changed nothing (review_all: true overrides).
    if not at_commit and not cfg.get("review_all") and not tr["edited"]:
        return 0

    def note(text):
        return emit({"systemMessage": text})

    def hold(reason):
        """Hold back the commit (or the end of the turn) and hand the findings to Claude."""
        if at_commit:
            return emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                "permissionDecisionReason": reason}})
        return emit({"decision": "block", "reason": reason})

    diff = changes(root)
    if not diff.strip():
        return 0
    if len(diff) > MAX_DIFF:
        diff = diff[:MAX_DIFF] + "\n… (diff truncated at %d characters)" % MAX_DIFF
    session = re.sub(r"[^A-Za-z0-9_-]", "", data.get("session_id") or "unknown")
    os.makedirs(STATE_DIR, exist_ok=True)
    state_path = os.path.join(STATE_DIR, session + ".json")
    try:
        with open(state_path) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}

    task = tr["prompt"]
    task_hash = hashlib.sha256(task.encode()).hexdigest()
    if state.get("task") != task_hash:                    # a new request gets fresh rounds
        state = {"task": task_hash, "rounds": 0, "best_score": -1.0, "best_ref": "", "last_diff": ""}
    diff_hash = hashlib.sha256(diff.encode()).hexdigest()
    if state.get("last_diff") == diff_hash:
        return 0                                          # nothing changed since the last review
    max_rounds = int(cfg.get("max_rounds", 1))
    if state["rounds"] >= max_rounds:
        state["last_diff"] = diff_hash
        json.dump(state, open(state_path, "w"))
        if at_commit:
            return note("LLM Switcher review: already reviewed for this request; committing.")
        return note("LLM Switcher review: stopped after %d round%s; check the remaining points yourself." % (max_rounds, "" if max_rounds == 1 else "s"))

    failures, test_note, regress = "", "", ""
    # Never run a repo's test command at commit time: that would run code from .llm-review.json before
    # the person has approved the commit. Tests run only in the after-the-turn ("when": "stop") mode.
    if cfg.get("test") and not at_commit:
        passed, score, out, summary = run_tests(cfg["test"], root, min(int(cfg.get("test_timeout", 600)), 900))
        test_note = " Tests (`%s`): %s." % (cfg["test"], summary)
        if not passed:
            failures = "Running `%s` failed:\n%s" % (cfg["test"], out)
        if score >= state["best_score"]:
            _, ref = run(["git", "stash", "create"], root)
            ref = ref.strip()
            if ref:
                run(["git", "update-ref", "refs/llm-switcher/best-" + session, ref], root)
                state["best_ref"] = ref
            state["best_score"] = score
        elif state["best_ref"]:
            regress = ("\n\nIMPORTANT: an earlier version passed more tests (%.0f%% vs %.0f%% now). If you can't "
                       "fix the regression quickly, restore that version with:\n`git restore --source=%s --worktree -- .`"
                       % (state["best_score"] * 100, score * 100, state["best_ref"]))

    # Light by default: the session's own model (already loaded, so no second big model has to
    # load) at medium thinking. .llm-review.json can name another reviewer or effort.
    reviewer = (cfg.get("reviewer") or tr["model"] or os.environ.get("ANTHROPIC_MODEL")
                or app_default("loop.reviewer", "Qwen3.8-Flash-Next-oQ4e-mtp"))
    effort = cfg.get("effort") or "medium"
    left = HOOK_BUDGET - (time.time() - started)
    if left < 120:
        return note("LLM Switcher review skipped: the tests used up the review's time. Lower test_timeout in .llm-review.json.")
    try:
        text = review(reviewer, effort, task, diff, failures, timeout=left)
    except Exception as e:
        return note("LLM Switcher review skipped: the reviewer couldn't be reached (%s)." % e)

    state["rounds"] += 1
    state["last_diff"] = diff_hash
    json.dump(state, open(state_path, "w"))
    clean = is_clean(text, failures)
    if clean:
        return note("LLM Switcher review (%s, %s): no issues found.%s" % (reviewer, effort, test_note))
    reason = (
        "A reviewer (%s, %s reasoning) checked your uncommitted changes%s. Round %d of %d.%s\n\n"
        "%s%s\n\nREVIEW:\n%s\n\n"
        "Verify each point against the code before changing anything: the reviewer can be wrong, while "
        "failing tests are ground truth. Fix the real problems, then %s. For any point you reject, "
        "say why in one line.%s"
        % (reviewer, effort, " before this commit" if at_commit else "", state["rounds"], max_rounds, test_note,
           failures[:3000], "\n" if failures else "", text[:8000] or "(empty review)",
           "commit again" if at_commit else "finish", regress))
    return hold(reason)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:                                # never break a session over the reviewer
        print(json.dumps({"systemMessage": "LLM Switcher review error: %s" % e}))
        sys.exit(0)
