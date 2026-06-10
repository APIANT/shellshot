# ShellShot

**One hotkey to send a screenshot — with annotations and a message — into any live Claude Code terminal session.**

Press ⌥⌘C, drag over the bug, draw a red arrow at the problem, type "why is this misaligned?", hit Enter. The screenshot and your message appear in your chosen Claude Code session as if you'd typed them there — full context preserved, no file dragging, no app switching, no API key.

There's also a recording mode (⌥⌘R): capture a region as a sequence of frames over time, auto-deduped perceptually, for UI bugs that can't be caught in a single still.

## Why this exists

Sharing what you're looking at with Claude Code is weirdly hard: screenshot → save → find the file → drag it into the terminal. The community has wanted user-initiated message/image injection into running sessions for a while (see anthropics/claude-code [#53049](https://github.com/anthropics/claude-code/issues/53049), [#24947](https://github.com/anthropics/claude-code/issues/24947), [#27441](https://github.com/anthropics/claude-code/issues/27441)) — but no official mechanism exists.

ShellShot's finding: **the terminal emulator itself is the injection point.** iTerm2's Python API can send text to any specific session — focused or not — exactly as if the user typed it. Claude Code reads image file paths natively. Put those together and you get true injection into your *existing* session, riding your existing subscription auth, with no Anthropic API involvement at all.

## Features

- **⌥⌘C** — area capture (native macOS crosshair) → preview panel → inject
- **⌥⌘R** — record a region: frames every 0.7s, perceptual dedup (dHash), capped at 20, filmstrip review
- **Arrow annotations** — drag on the preview to draw Monosnap-style red arrows, composited at full resolution
- **Session picker** — all live Claude Code sessions, labeled by project directory + session title + last activity; auto-selects the focused session
- **Clipboard** — every send also lands on your clipboard at full resolution; or "Copy to Clipboard" to skip Claude entirely
- **Token-aware** — images sent to Claude are downscaled (1280px regions / 2000px full-screens, JPEG q75); your clipboard copy stays full-res
- Menubar app, launch-at-login, auto-prunes captures after 7 days

## Requirements

- macOS 13+
- [iTerm2](https://iterm2.com) with the Python API enabled: **Settings → General → Magic → Enable Python API**
- Python 3 (for the iTerm2 sidecar; `brew install python` if needed)
- Claude Code running in iTerm2

## Install

```bash
git clone https://github.com/APIANT/shellshot ~/shellshot
cd ~/shellshot

# sidecar venv (talks the iTerm2 API)
python3 -m venv prototype/.venv
prototype/.venv/bin/pip install iterm2

# build + install /Applications/ShellShot.app
./app/build-app.sh
open /Applications/ShellShot.app
```

First capture will prompt for **Screen Recording** permission (System Settings → Privacy & Security). First sidecar call will prompt to allow automation of iTerm2. Both are one-time.

> The app currently expects this repo at `~/shellshot` (or set `SHELLSHOT_ROOT`). Self-contained packaging of the Python sidecar is on the roadmap.

## How it works

```
⌥⌘C ──> screencapture -i ──> SwiftUI panel (preview / arrows / session picker / message)
                                        │ Enter
                                        ▼
                       Python sidecar (iTerm2 websocket API)
                                        │ async_send_text()
                                        ▼
                "Look at /path/shot.png — why is this misaligned?" ⏎
                     appears in your live Claude Code session
```

Session discovery is deliberately *not* done via iTerm2's job variables — Claude Code spawns MCP-server children, so iTerm2's `jobName` often reports `python`/`node` instead of `claude`. ShellShot instead sweeps `ps` for `claude` processes and matches their ttys to iTerm2 sessions, pulling each session's cwd via `lsof` and last-activity from Claude's own transcript files.

## Roadmap

- tmux / Kitty / WezTerm adapters (the injection layer is pluggable; tmux also covers SSH'd Linux sessions)
- HTTP listener + iPadOS Shortcut — capture on the iPad, inject into the laptop's session
- Self-contained sidecar (no Python setup)
- Clipboard-paste fallback adapter for Terminal.app / VS Code / Warp

## Provenance

Designed and built in one day, almost entirely by Claude Code (research, architecture, Swift, Python, this README). The feasibility research that killed three wrong architectures before landing on terminal-level injection is preserved in [docs/product-brief.md](docs/product-brief.md).

## License

MIT
