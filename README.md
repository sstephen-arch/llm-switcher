# LLM Switcher

**One menu bar app for running Claude Desktop, Claude Code, Codex and your other AI tools on local
models on a Mac, across several inference engines, without the setup pain.**

Running models locally on Apple Silicon is fast now, but using them is fiddly. Every engine (oMLX,
Splash, Ollama, LM Studio, llama.cpp) has its own port, its own model list, its own way to tune
sampling, and its own idea of which API it speaks. Pointing Claude Desktop, Claude Code or Codex
at a local model means editing config files and environment variables by hand, and two engines
started on the same port quietly break each other. Sharing a model with another computer in the
house means exposing an engine's admin key.

LLM Switcher sits in front of all of that. It runs a small gateway on your Mac that speaks the
three APIs today's tools use (OpenAI Chat Completions, OpenAI Responses, Anthropic Messages),
routes each request to whichever engine serves that model, starts engines when they are needed,
applies each model's tuned settings, and lets you switch Claude Desktop between the cloud and your
local models with one button.

> Status: a working personal tool, built and used daily on an M5 Max MacBook Pro (128 GB). It is
> early, opinionated and Mac-only. Contributions are very welcome; see
> [Where it needs help](#where-it-needs-help).
>
> Not affiliated with Anthropic, OpenAI, or any engine project. "Claude", "Codex" and the engine
> names belong to their owners; LLM Switcher just talks to them.

---

## What it does

### Claude Desktop on local models, one click
Claude Desktop has a "gateway" mode for third-party deployments. LLM Switcher writes that profile
for you, restarts Claude, and maps Claude's fixed model slots (Fable, Opus, Sonnet, Haiku…) to
whichever local models you pick. **Back to Claude cloud** puts everything back. Each engine keeps
its own slot picks, so switching engines and back loses nothing.

### Many engines, one list
| Engine | How LLM Switcher drives it | Model names in LLM Switcher |
|---|---|---|
| [oMLX](https://github.com/jundot/omlx) | Opens the oMLX app; uses its admin API for per-model settings, load/unload, safe reloads and upgrades | plain names, e.g. `Qwen3.8-Flash-Next-oQ4e-mtp` |
| [Splash](https://github.com/incoai/splash) | Starts `splash serve` itself (one model at a time, DFlash2 speculative decoding) | `splash/<repo-name>` |
| [Ollama](https://ollama.com) | Starts `ollama serve` with the context window you choose, or uses an Ollama already running | `ollama/<name:tag>` |
| [LM Studio](https://lmstudio.ai) | `lms server start/stop` | `lmstudio/<model-key>` |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | Starts `llama-server` in multi-model (router) mode with a private key | `llamacpp/<org/repo:QUANT>` |

- **Engines start on demand.** A request for a stopped engine's model starts that engine and
  waits for it (only engines you have switched on; another computer can't switch one on for you).
  Splash stops itself after a quiet spell when Claude isn't using it, to give back its memory.
- **Every installed model is always pickable**, whether or not its engine is running: oMLX's
  models folder, Splash's downloads, llama.cpp's and Ollama's caches are read from disk.
- **Ports never clash.** The Engines tab shows every port (gateway, sharing, each engine), who is
  actually listening on it, and refuses a port another service already uses.

### Tuned settings, applied everywhere
Untuned local models loop, overthink or ramble. LLM Switcher:
- **Finds each model's recommended settings** from the people who made or packaged it (Unsloth's
  tuned `params`, the model's and its base model's `generation_config.json`) and reads its chat
  template for thinking switches and levels. Shows them next to what's set now; one click applies.
- **Applies per-model presets in the gateway**: thinking level, minimum reply length, sampling
  defaults, a backup model, and an optional lock that ignores the sampling values apps send.
- **Makes "thinking off" actually work** on engines that ignore Anthropic's `thinking: disabled`
  (it also flips the chat template's `enable_thinking` switch).

### Share models with other computers, safely
Turn on **Network sharing** and other machines on your network (Windows too) can use your models
through one URL with **per-person keys**, concurrency and per-minute limits, optional HTTPS with a
self-signed certificate, Bonjour discovery and copy-paste setup snippets for OpenCode, Claude Code,
Codex and PowerShell. Engine admin keys never leave the Mac; only private-network addresses are
accepted.

### See what's happening
- **Requests tab:** every request's time to first word, prompt reading speed, writing speed and
  prompt-cache reuse, per model and per request (numbers only; prompts and replies are never
  stored).
- **Usage tab:** daily tokens per person and per model.
- **System tab:** CPU, GPU and memory, plus oMLX's own serving stats and prompt cache per model.

### Benchmark any model
One click (or `lsw bench`) runs: writing speed, reading speed on a long prompt with a hidden-word
recall check, four requests at once, a tool call, and 12 coding problems graded by hidden tests.
It runs through the gateway, so models are tested with the settings your tools actually get, and
never sends its own temperature. The model's code runs in a macOS sandbox: no network, no reading
your home folder, writes only in its own temp folder, no other programs, 30 seconds.

### A terminal command: `lsw`
```
lsw status                  engines, which one Claude uses, slot picks
lsw models                  every installed model, by engine
lsw use <engine>            switch engine
lsw start|stop <engine>
lsw claude [slot] [args]    Claude Code on a local model (lean setup for fast local prefill)
lsw codex [model] [args]    Codex on a local model
lsw tune <model>            recommended settings for a model
lsw bench <model> [hard|all|none] [default|off|low|medium|high]
```

### Also inside
- **Models tab:** search Hugging Face for MLX models with a fit check against your memory and a
  compatibility check against your oMLX before download; resumable downloads; oMLX per-model
  settings; clean removal (unload, settings, folder and prompt-cache files to the Trash).
- **Review loop:** a writer model drafts code, a reviewer model critiques it, optional test
  command, keeps the best round. A Claude Code `Stop` hook (`scripts/llm-review-hook.py`) does the
  same for local Claude Code sessions.
- **Watchdog:** when an engine silently drops a request (oMLX does when it reloads), the client gets
  a clear error after ~90 s instead of hanging forever.

---

## How it fits together

```
 Claude Desktop ─┐                                   ┌─> oMLX        :8000
 Claude Code ────┤   LLM Switcher gateway            ├─> Splash      :8100
 Codex ──────────┼─> 127.0.0.1:11436 (this Mac)  ────┼─> Ollama      :11434
 lsw / scripts ──┤   0.0.0.0:11437 (sharing, keys)   ├─> LM Studio   :1234
 Other computers ┘   route by model name, presets,   └─> llama.cpp   :8300
                     on-demand start, usage, watchdog
```

- The gateway (`Sources/ClaudeLocal/Gateway.swift`, Network.framework) handles
  `/v1/chat/completions`, `/v1/completions`, `/v1/responses`, `/v1/messages`,
  `/v1/messages/count_tokens`, `/v1/embeddings` and `/v1/models`, streams replies through as they
  arrive, and adds each engine's own key.
- `Engines.swift` maps a model name to its engine (by prefix) and builds the catalog;
  `Splash.swift` and `ExternalEngine.swift` start, watch and stop engines; `OMLXAdmin.swift` talks
  to oMLX's admin API.
- Settings live in `~/Library/Application Support/ClaudeLocal/config.json` (owner-only; the gateway
  re-reads it on every request). Logs are in `~/Library/Logs/ClaudeLocal/`.
- The internal names still say "ClaudeLocal" (the app's first name): Xcode target, bundle id
  `com.depaloconsulting.claudelocal`, folders. Renaming them would break existing installs.

## Build it

Requirements: Apple Silicon Mac, macOS 14 or later, a recent Xcode (developed with Xcode 27), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open ClaudeLocal.xcodeproj
```

In Xcode, pick your own team under Signing & Capabilities, or put
`DEVELOPMENT_TEAM = <your team id>` in `Config/Local.xcconfig` (git-ignored), then Run. The app lives in the menu bar. Tests:

```bash
xcodebuild -project ClaudeLocal.xcodeproj -scheme ClaudeLocal test
```

`scripts/release.sh` builds, Developer-ID-signs, notarizes and packages a DMG; it needs your own
App Store Connect API key (see the top of the script). You don't need it to build for yourself.

You'll want at least one engine installed: oMLX (download from its releases), Splash
(`brew install incoai/tap/splash`), Ollama, LM Studio or llama.cpp (`brew install llama.cpp`).

## Security model (short version)
- The gateway on `127.0.0.1:11436` takes no key: anything on this Mac can use it, as it can use the
  engines. Requests carrying a browser `Origin` header are refused.
- Sharing on `:11437` needs a per-person key, accepts only private-network addresses (LAN,
  Tailscale/CGNAT, IPv6 ULA), limits request size, and never exposes engine admin APIs.
- Engine keys (oMLX's, Splash's, llama.cpp's) are added by the gateway and never sent out; keys LLM
  Switcher generates are passed to engines in their environment, never on the command line.
- Benchmark code runs under `sandbox-exec` (see above).

Found a problem? Please open an issue, or for anything sensitive, a private security advisory on
GitHub.

## Where it needs help
Ideas that would make it better, roughly in order of value:

1. **Real-world testing with Ollama and LM Studio.** Both are wired in but were only tested against
   stand-in servers. Reports and fixes from real use are the most useful thing right now.
2. **A memory budget across engines.** oMLX doesn't know about Splash's model and vice versa.
   Before starting a model, add up what every engine has loaded and offer to unload what won't fit.
3. **UI tests and screenshots.** The menu bar app is hard to automate; XCUITest coverage of the
   menu and Settings would catch regressions the unit tests can't.
4. **More engines:** vllm-metal, mlx-lm's server (OpenAI-only), anything else with an
   Anthropic-compatible endpoint.
5. **Remote access, done safely:** pairing, a connect helper for other computers, an iPhone app.
   A design is in [`docs/remote-access-design.md`](docs/remote-access-design.md).
6. **Auto-updates.** Sparkle is built in; it needs a hosted appcast feed.
7. **An MCP endpoint** so Claude can check status or switch models itself.
8. **Better benchmarks:** more problem sets, repeated runs with averages, agentic tasks.

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md). Small, focused pull requests with a test where it makes
sense are easiest to review. Please describe what you tested on (Mac, engine, model).

## Licence
[MIT](LICENSE) © 2026 DePalo Consulting LLC.
