# ShellShot 🦞📸

**Stop describing your bugs to Claude. Show it.**

You're staring at a misaligned button, a broken layout, a stack trace in a dialog. Claude Code is right there in your terminal, ready to fix it — and your workflow is *screenshot, save, find the file, drag it into the terminal, apologize for the wait*. Like a courier pigeon between two apps on the same machine.

ShellShot deletes the pigeon. **⌥⌘C** — crosshair over the bug — draw a fat red arrow at the crime scene — type *"why is this misaligned?"* — Enter. The annotated screenshot lands in your live Claude Code session as if you'd typed it there yourself. Full conversation context preserved. No file dragging. No app switching. No API key. Two seconds, screen to session.

Got a bug that only exists *in motion* — a flicker, a botched animation, a progress bar that lies? **⌥⌘R** records a region as a timed frame sequence, perceptually dedups the boring parts, and ships Claude a filmstrip.

## The trick

Anthropic ships no way to inject a message into a running Claude Code session — it's one of the most-asked-for missing features ([#53049](https://github.com/anthropics/claude-code/issues/53049), [#24947](https://github.com/anthropics/claude-code/issues/24947), [#27441](https://github.com/anthropics/claude-code/issues/27441)). The SDK can't do it. The private APIs can't be trusted. Everyone's workaround is folder-polling hacks.

ShellShot's answer: **go through the terminal, not through Anthropic.** iTerm2's Python API can type into any session — focused or not, minimized or not — exactly as if your fingers did it. Claude Code happily reads image paths from a prompt. Chain them and you get true injection into the session you already have open, on the subscription auth you already pay for, with zero Anthropic API surface. The session doesn't even know ShellShot exists.

> **macOS + iTerm2 only, for now.** ShellShot is a Mac menubar app, and the injection layer currently speaks only iTerm2's API. The layer is pluggable — tmux / Kitty / WezTerm adapters are on the roadmap (`send-keys` and friends make them straightforward, and tmux would cover SSH'd Linux sessions) — but today, if you're not on a Mac with your Claude Code sessions in iTerm2, ShellShot can't reach them.

## What you get

- **⌥⌘C capture** — native crosshair → big preview panel → inject
- **Red arrows** — drag on the preview, Monosnap-style tapered arrows, composited at full resolution. An arrow beats a paragraph of "the button in the upper-left-ish area"
- **⌥⌘R recording** — frames every 0.7s, dHash perceptual dedup (a static screen contributes one frame, not forty), capped at 20, reviewable filmstrip with per-frame delete
- **Session picker that reads your mind** — every live Claude Code session labeled by project + session title + recency; preselects the focused one, falls back to the last one you used
- **Clipboard, both ways** — every send also lands full-res on your clipboard for Slack/PRs; or hit "Copy to Clipboard" and skip Claude entirely
- **Token-aware** — Claude receives downscaled JPEGs (1280px regions, 2000px full-screens — still crisp enough to read your sidebar filenames); your clipboard keeps every pixel
- Menubar app, launch-at-login, captures auto-prune after 7 days

## Requirements

- macOS 13+
- [iTerm2](https://iterm2.com) with **Settings → General → Magic → Enable Python API** checked
- Python 3 — *build time only*; the installed app embeds a self-contained sidecar
- Claude Code sessions running in iTerm2

## Install

```bash
git clone https://github.com/APIANT/shellshot ~/shellshot
cd ~/shellshot

# one-time build deps (embedded into the app, not needed at runtime)
python3 -m venv prototype/.venv
prototype/.venv/bin/pip install iterm2 pyinstaller

./app/build-app.sh        # builds Swift app + PyInstaller sidecar → /Applications
open /Applications/ShellShot.app
```

Two one-time permission prompts: **Screen Recording** (first capture) and **automation of iTerm2** (first send). The installed .app is fully self-contained — the repo and venv are only needed to build it.

## How it works

```
⌥⌘C ──> screencapture -i ──> SwiftUI panel (preview · arrows · session picker · message)
                                        │ Enter
                                        ▼
                    bundled sidecar ── iTerm2 websocket API
                                        │ async_send_text()
                                        ▼
              "Look at /path/shot.png — why is this misaligned?" ⏎
                   …appears in your live Claude Code session
```

One field note for anyone building on the same trick: don't trust iTerm2's `jobName` to find Claude sessions — Claude Code spawns MCP-server children, so iTerm2 reports `python` or `node` instead of `claude`. ShellShot sweeps `ps` for `claude` processes and matches ttys to iTerm2 sessions, pulling cwd via `lsof` and last-activity from Claude's own transcript files.

## Roadmap

- tmux / Kitty / WezTerm adapters (tmux also covers SSH'd Linux sessions)
- HTTP listener + iPadOS Shortcut — capture on the iPad, land in the laptop's session
- Clipboard-paste fallback for Terminal.app / VS Code / Warp

## License

MIT © APIANT Inc.
