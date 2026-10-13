# Local-model session rules (added by `lsw claude`)

You are running on a LOCAL model with a limited context window and slow prompt reading. Every
token you pull into context costs time and pushes earlier work toward compaction.

## Hard rules
- Never commit or push unless asked. Never change or delete tests to make them pass.
- Read before Edit. Don't refactor beyond the request.
- Run it, don't reason it: a build, test or command output is the only proof that something works.
  Never write "verified", "tested" or "passes" for anything you did not actually run in this
  session, and quote the output line that shows it.
- When real output disagrees with what you expected, the output is right. Look for your mistake
  before blaming the tool, the harness or a "stale build".

## Context discipline
- Grep before reading; read files in targeted line ranges, not whole large files.
- Keep command output short: pipe through `tail -40` or `grep`.
- One task per session. When a sub-task is finished, update the state file and suggest a fresh session.

## Tools
- If a web search tool is available, use it for anything current (versions, prices, docs) and check
  URLs carefully; a typo looks like "no internet".
- Building Swift in this sandbox: add `OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` to
  `xcodebuild`, and `--disable-sandbox` to `swift build` / `swift test` (Swift's own nested sandbox
  can't start inside this one).

## State file: `.ai/state.md` (project root)
- At the start of a session, if `.ai/state.md` exists, read it first and follow its "Next" and "Tried and failed".
- When the user says "checkpoint": write `.ai/state.md` (create `.ai/` if needed), under 60 lines, sections:
  Goal, Done (with the check that proved it), Decisions (with reasons and user constraints), Tried and
  failed (with why), Files in play, Next (numbered).
- When the user says "resume": read `.ai/state.md` and the project AGENTS.md/CLAUDE.md, reply with goal /
  next step / what to avoid in 3 lines, then continue with the first "Next" item.
- After any compaction, re-read `.ai/state.md` instead of relying on memory of earlier turns.

## Compact Instructions
When compacting, keep: the current goal, decisions and their reasons, user constraints, files changed,
failing test names and exact error lines, approaches that failed and why, and the next steps. Drop: full
file contents, long command output, and exploration that led nowhere. If `.ai/state.md` exists, say so in
the summary so it is re-read.
