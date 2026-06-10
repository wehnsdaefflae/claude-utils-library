#!/usr/bin/env python3
"""SessionStart hook for the global utils library.

Registered in ~/.claude/settings.json under hooks.SessionStart with matcher
"startup|resume|clear|compact" — all four sources. The compact matcher does
double duty: hook-injected context does not survive compaction (the old
snapshot vanishes at exactly that moment), and the re-fire runs `gu list`
fresh, so every compaction is also a refresh.

Runs `gu list` against the resolved library home and emits the catalog as
additionalContext. Silent when the library is absent or empty, and ALWAYS
exits 0 — a SessionStart hook must never disrupt a session.
"""
import json
import os
import subprocess
import sys


def main() -> None:
    home = os.environ.get("GLOBAL_UTILS_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share", "global-utils"
    )
    gu = os.path.join(home, "gu")
    utils_dir = os.path.join(home, "utils")
    if not os.path.isfile(gu) or not os.path.isdir(utils_dir):
        return
    has_utils = any(
        os.path.isfile(os.path.join(utils_dir, entry, "main.py"))
        for entry in os.listdir(utils_dir)
    )
    if not has_utils:
        return  # nothing to push yet — the CLAUDE.md pointer line still covers discovery
    try:
        result = subprocess.run(
            [sys.executable, gu, "list"], capture_output=True, text=True, timeout=15
        )
    except Exception:
        return
    if result.returncode != 0 or not result.stdout.strip():
        return
    context = (
        "Global utils — catalog snapshot (a cache: run `gu list` for current state). "
        "These are real CLI commands; run one with `gu <name> [args]`. Prefer an "
        "existing util over writing an inline one-off. If a util errors or misbehaves "
        "mid-use, repair it via the revise-util skill (selftest-gated, committed).\n"
        + result.stdout
    )
    json.dump(
        {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}},
        sys.stdout,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never fail a SessionStart hook
    sys.exit(0)
