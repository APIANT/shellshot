#!/usr/bin/env python3
"""ShellShot prototype: capture a screenshot and inject it into a live
Claude Code session running in iTerm2.

Usage:
  shellshot.py list                     List sessions running claude
  shellshot.py send [opts] [message]    Capture + inject into a session

Options for send:
  --session ID      Target iTerm2 session id (default: most relevant claude session)
  --image PATH      Use existing image(s) instead of capturing (repeatable)
  --no-capture      Send message only, no image
  --no-submit       Type the text but don't press Enter
  --full            Capture full screen (non-interactive) instead of area select
  --dry-run         Print what would be sent, don't inject
"""

import argparse
import asyncio
import datetime
import json
import os
import subprocess
import sys
import tempfile

import iterm2

SHOT_DIR = os.path.expanduser("~/Library/Application Support/ShellShot/shots")


def claude_ttys():
    """Map tty (e.g. 'ttys016') -> claude pid, via one ps sweep.

    iTerm2's jobName/commandLine report the session's *foreground* job, which
    for Claude Code is often a spawned MCP-server child (python/node) — so
    detection must go by tty, not by iTerm2's job variables.
    """
    ps = subprocess.run(
        ["ps", "-axo", "pid=,tty=,comm="], capture_output=True, text=True,
    )
    out = {}
    for line in ps.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] != "??" and parts[2] == "claude":
            out[parts[1]] = int(parts[0])
    return out


async def claude_sessions(app):
    """Return [(session, info)] for sessions whose tty hosts a claude process."""
    by_tty = claude_ttys()
    active_id = None
    try:
        w = app.current_terminal_window
        if w:
            active_id = w.current_tab.current_session.session_id
    except AttributeError:
        pass
    out = []
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                tty = await session.async_get_variable("tty") or ""
                pid = by_tty.get(tty.replace("/dev/", ""))
                if pid is None:
                    continue
                info = {
                    "session_id": session.session_id,
                    "pid": pid,
                    "tty": tty,
                    "commandLine": await session.async_get_variable("commandLine"),
                    "path": cwd_of_pid(pid),
                    "name": await session.async_get_variable("autoName"),
                    "is_active": session.session_id == active_id,
                }
                info["last_active"] = last_activity(info["path"])
                out.append((session, info))
    out.sort(key=lambda x: x[1]["last_active"] or 0, reverse=True)
    return out


def last_activity(cwd):
    """Newest Claude transcript mtime for a cwd (epoch seconds), or None."""
    if not cwd:
        return None
    enc = "".join(c if c.isalnum() else "-" for c in cwd)
    proj = os.path.expanduser(f"~/.claude/projects/{enc}")
    try:
        times = [
            os.path.getmtime(os.path.join(proj, f))
            for f in os.listdir(proj) if f.endswith(".jsonl")
        ]
        return max(times) if times else None
    except OSError:
        return None


def cwd_of_pid(pid):
    """cwd of a process via lsof."""
    lsof = subprocess.run(
        ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
        capture_output=True, text=True,
    )
    for l in lsof.stdout.splitlines():
        if l.startswith("n"):
            return l[1:]
    return None


def capture(interactive=True):
    """Capture screenshot, return path or None if user cancelled."""
    os.makedirs(SHOT_DIR, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = os.path.join(SHOT_DIR, f"shot-{stamp}.png")
    cmd = ["screencapture"]
    cmd.append("-i" if interactive else "-x")
    cmd.append(path)
    subprocess.run(cmd, check=True)
    if not os.path.exists(path):  # user hit Esc
        return None
    return path


def bracketed(text):
    """Wrap text in bracketed-paste escapes so a multi-line message is
    treated as one paste by the TUI instead of submitting per line."""
    return "\x1b[200~" + text + "\x1b[201~"


async def inject(session, image_paths, message, submit=True):
    parts = []
    if len(image_paths) == 1:
        parts.append(f"Look at {image_paths[0]}")
    elif image_paths:
        parts.append(
            f"Look at this sequence of {len(image_paths)} frames captured "
            "over time, in order: " + " ".join(image_paths)
        )
    if message:
        parts.append(message)
    if not parts:
        return ""
    text = " — ".join(parts) if len(parts) == 2 else parts[0]
    payload = bracketed(text) if "\n" in text else text
    await session.async_send_text(payload, suppress_broadcast=True)
    if submit:
        await asyncio.sleep(0.15)  # let the TUI ingest the paste before submit
        await session.async_send_text("\r", suppress_broadcast=True)
    return text


def fmt(info):
    return (f"  {info['session_id']}\n"
            f"    cwd:  {info['path'] or '?'}\n"
            f"    pid:  {info['pid']}\n"
            f"    tty:  {info['tty']}")


async def amain(connection, args):
    app = await iterm2.async_get_app(connection)
    found = await claude_sessions(app)

    if args.cmd == "list":
        if args.json:
            print(json.dumps([info for _, info in found]))
            return
        if not found:
            print("No iTerm2 sessions running claude.")
            return
        print(f"{len(found)} claude session(s):")
        for _, info in found:
            print(fmt(info))
        return

    # send
    if not found:
        sys.exit("No iTerm2 sessions running claude.")
    target = None
    if args.session:
        for s, info in found:
            if s.session_id == args.session:
                target = (s, info)
        if not target:
            sys.exit(f"Session {args.session} not found among claude sessions.")
    elif len(found) == 1:
        target = found[0]
    else:
        print("Multiple claude sessions, pick one with --session:")
        for _, info in found:
            print(fmt(info))
        sys.exit(1)

    session, info = target
    images = args.image or []
    if not images and not args.no_capture:
        shot = capture(interactive=not args.full)
        if shot is None:
            sys.exit("Capture cancelled.")
        images = [shot]

    if args.dry_run:
        print(f"Would inject into {info['session_id']} ({info['path']}):")
        print(f"  images:  {images}")
        print(f"  message: {args.message}")
        return

    text = await inject(session, images, args.message, submit=not args.no_submit)
    print(f"Injected into {info['session_id']} ({info['path'] or 'cwd ?'}):")
    print(f"  {text!r}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("list")
    pl.add_argument("--json", action="store_true")
    ps = sub.add_parser("send")
    ps.add_argument("--session")
    ps.add_argument("--image", action="append")
    ps.add_argument("--no-capture", action="store_true")
    ps.add_argument("--no-submit", action="store_true",
                    help="type the text but don't press Enter")
    ps.add_argument("--full", action="store_true")
    ps.add_argument("--dry-run", action="store_true")
    ps.add_argument("message", nargs="?", default="")
    args = p.parse_args()

    async def runner(connection):
        await amain(connection, args)

    iterm2.run_until_complete(runner)


if __name__ == "__main__":
    main()
