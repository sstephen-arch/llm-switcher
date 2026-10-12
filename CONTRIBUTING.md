# Contributing to LLM Switcher

Thanks for helping. LLM Switcher is a small native macOS app (SwiftUI, Network.framework, no
third-party dependencies besides Sparkle), so it's quick to get going.

## Getting set up
1. `brew install xcodegen`, then `xcodegen generate` in the repo (the `.xcodeproj` is generated,
   not committed).
2. Open `ClaudeLocal.xcodeproj`, choose your own signing team (or set `DEVELOPMENT_TEAM` in a
   git-ignored `Config/Local.xcconfig`), Run.
3. Install at least one engine (see the README) so there's something to route to.

Only one copy of the app runs at a time: quit an installed copy before running yours from Xcode.

## Before you open a pull request
- `xcodebuild -project ClaudeLocal.xcodeproj -scheme ClaudeLocal test` passes. Add a test for new
  logic where you can (parsing, routing, presets, config migration are all unit-testable).
- If you touched `scripts/lsw`, run `zsh -n scripts/lsw`. It uses the system Python 3.9 for JSON,
  so avoid newer Python syntax there.
- Say what you tested on: Mac model and memory, macOS version, engine and version, model.
- Keep pull requests focused. One fix or feature per pull request is easiest to review.

## Things to keep in mind
- **Never break existing installs.** `config.json` is decoded leniently on purpose; a new setting
  needs a default when it's missing. The internal "ClaudeLocal" names (bundle id, folders, Xcode
  target) stay as they are.
- **Privacy:** the usage and request logs keep numbers only. Don't add prompt or reply text to
  anything written to disk.
- **Keys stay local:** engine keys are added inside the gateway; keys the app generates go to
  engines in their environment, never on the command line or in logs.
- **Don't send a temperature** (or other sampling) from built-in features like the benchmark or the
  review loop. Each model's tuned settings should apply.
- **UI copy** is short and plain: say what the user sees and what to do, no jargon.

## Ideas
See [Where it needs help](README.md#where-it-needs-help) in the README. Opening an issue to discuss
a bigger change first is welcome.
