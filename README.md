# ShellShot

A macOS menubar app that sends screenshots directly into a running Claude Code iTerm2 terminal session.

## The problem

Sharing what's on your screen with Claude Code is tedious: take a screenshot, save it, locate the file, drag it into the terminal. There is no supported way to inject a message into a running session from outside ([#53049](https://github.com/anthropics/claude-code/issues/53049), [#24947](https://github.com/anthropics/claude-code/issues/24947), [#27441](https://github.com/anthropics/claude-code/issues/27441)).

ShellShot goes through the terminal instead: iTerm2's Python API can send text to any session as if it were typed, and Claude Code reads image paths from a prompt. Press a hotkey, select a screen region, optionally draw an arrow and add a message, and it lands in the session you choose — using your existing Claude subscription, no API key.

## Features

- **⌥⌘C** — area capture, preview, annotate with arrows, send
- **⌥⌘R** — record a region as a frame sequence (perceptually deduped, max 20 frames)
- Session picker across all live Claude Code sessions; preselects the focused one
- Sent images are also copied to the clipboard at full resolution
- Images sent to Claude are downscaled to keep token usage reasonable
- Launch at login; captures auto-prune after 7 days

**Supports macOS + iTerm2 only.** tmux, Kitty, and WezTerm adapters are planned.

## Install

Requires macOS 13+, [iTerm2](https://iterm2.com) with **Settings → General → Magic → Enable Python API**, and Python 3 (build time only).

```bash
git clone https://github.com/APIANT/shellshot ~/shellshot
cd ~/shellshot
python3 -m venv prototype/.venv
prototype/.venv/bin/pip install iterm2 pyinstaller
./app/build-app.sh
open /Applications/ShellShot.app
```

macOS will prompt once for Screen Recording and once for iTerm2 automation. The installed app is self-contained.

## License

MIT © APIANT Inc.
