# ShellShot

A macOS menubar app that sends screenshots and short recordings directly into a running Claude Code iTerm2 terminal session.

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
