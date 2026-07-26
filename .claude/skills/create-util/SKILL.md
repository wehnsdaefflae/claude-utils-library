---
name: create-util
description: Build a new util in the global utils library — most often by promoting a reusable one-off script just written into a permanent `gu` command. Use on explicit /create-util, or after the user has said an explicit yes to an offer to promote. Never writes to the library without that explicit confirmation.
argument-hint: "[optional: what the util should do — or empty to promote the script just written]"
allowed-tools: Read Write Edit AskUserQuestion WebSearch WebFetch Bash(gu *) Bash(git *) Bash(uv *) Bash(echo *) Bash(cat *) Bash(head *) Bash(ls *) Bash(mkdir *) Bash(printf *) Bash(find *) Bash(command *) Bash(chmod *)
---

Library home (LIB): !`echo "${GLOBAL_UTILS_HOME:-$HOME/.local/share/global-utils}"`
Dispatcher on PATH: !`command -v gu 2>/dev/null || echo "(gu not found — first-run setup needed, see step 0)"`
Fresh catalog — the source of truth; any in-context snapshot may be stale:
!`gu list 2>&1 || true`

Request (optional): `$ARGUMENTS`

Call that library path **LIB**. You are about to add a util — a real CLI command, invoked as
`gu <slug>`, shared across every project and session. **Gate: the user must have explicitly
asked for or confirmed this creation.** If you offered to promote a one-off and have not yet
received a clear yes, stop and ask — the library only ever gains utils the user approved.

## 0. First-run setup (only if the dispatcher is missing)
If `gu` is not on PATH above, the system is not installed on this machine. Setup is
`deploy.sh` in the `claude-utils-library` repo — it creates LIB (git-initialized), installs
`gu` (checking for the GraalVM `gu` collision), and registers both discovery layers. Ask the
user where their clone lives (or to clone it) and run `./deploy.sh`, then continue. If they
want a custom location, they export `GLOBAL_UTILS_HOME` in their shell rc — the env var is the
only persistence of a custom location; never record it in a file inside LIB.

## 1. Sync, then reuse & factoring check (before writing anything)
**Pull LIB first — the catalog above is derived from the local tree only.** Other machines
push to the same remote, so without a pull you can spend the whole skill building a util
that already exists upstream (this happened: two independently created `deepgram` twins had
to be hand-merged out of a rebase conflict).
- `git -C "$LIB" pull --rebase --autostash`, then re-derive with `gu list` and use THAT
  listing below.
- Remote unreachable/offline → proceed on the local tree, but say so in the final report.
- Pull hits a conflict → resolve it (or `git -C "$LIB" rebase --abort` and surface to the
  user) **before** creating anything.

Compare the need against the re-derived catalog:
- **An existing util already covers the core need** (or would with a modest extension) →
  do not create a near-duplicate. Propose revising it instead and switch to the
  `revise-util` skill on the user's go-ahead.
- **Existing utils cover sub-parts** → compose them: the new util calls
  `gu <name> --json` as a subprocess (see the composition pattern in step 3) rather than
  reimplementing their logic inline. Check `gu deps <name>` when unsure what a candidate
  already pulls in.

Then decide where the util boundaries fall. The reuse bullets ask "is this already a util?";
these ask "should this be *one* util at all?" — the inverse direction, and just as mandatory:
- **The candidate bundles separable responsibilities** → factor it before scaffolding. A
  one-off that mixes, say, a deterministic transform + side-effecting I/O + a flaky heuristic
  + an orchestration layer becomes several single-purpose utils composed at the CLI boundary,
  not one monolith. Prefer *splitting* a new util as readily as you prefer *not duplicating*
  an existing one.
- **One part is unreliable** (an OCR/layout guess, a scrape, any heuristic) → quarantine it in
  its own util so its flakiness can't contaminate the deterministic core, and so it can be
  selftested, revised, or swapped independently.
- **The reusable thing is data, not code** → don't write a util for it. A saved spec/template
  (e.g. field coordinates for a recurring form) consumed by a *generic* util is the right
  artifact: build the generic util once, keep the spec as plain data.
- **YAGNI brake** → extract only the seams *proven* reusable now. Build the part you have
  actually exercised; name the rest as future seams in the docstring rather than speculatively
  splitting utils no second caller needs yet. Decomposition is a factoring judgement, not an
  invitation to over-build.

## 2. Package research (before hand-rolling non-trivial logic)
Per-util isolation (`uv run` + PEP 723) makes a dependency near-free, so the bar for
reimplementing solved problems is high. For any non-trivial core logic, search PyPI / the web
for an established, well-maintained package (e.g. `charset-normalizer` over hand-written
encoding detection) and prefer adding it to the PEP 723 header. Skip the search only for
logic that is genuinely trivial or stdlib-obvious.

## 3. Scaffold `LIB/utils/<slug>/main.py`
Pick a short kebab-case slug — never one of the reserved gu commands (`list`, `help`,
`lint`, `deps`, `remove`, `index`). The file must conform to the doc standard:

```python
# /// script
# dependencies = []
# ///
"""<slug> — <one-line summary; this line IS the catalog entry>.

usage: gu <slug> <args...> [--json]
calls: (none)
tags: <tag>, <tag>
net: none
secrets: (none)
"""

import argparse
import json
import sys

FIXTURE = ...  # built-in data for --selftest


def run(...):
    """Core logic. Returns data; never prints."""


def selftest() -> int:
    result = run(FIXTURE, ...)
    assert result == ...,  f"unexpected: {result!r}"
    print("selftest: ok", file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="gu <slug>", description="<summary>")
    parser.add_argument("--json", action="store_true", help="structured JSON on stdout")
    parser.add_argument("--selftest", action="store_true", help="run built-in checks")
    # ... the util's own arguments ...
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    try:
        result = run(...)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if args.json:
        json.dump(result, sys.stdout)
        print()
    else:
        print(...)  # human-readable
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Non-negotiables (composition lives or dies on these):
- **Docstring header** — the util's ONLY machine-read surface, and read by more than the
  catalog (see below). All six lines are required; `gu lint` rejects a missing one:
  - first line `<slug> — <summary>` (em dash, slug = directory name)
  - `usage:` showing `gu <slug> ...`
  - `calls:` — every util this one invokes, or `(none)`
  - `tags:` — at least one, comma-separated
  - `net: outbound` if the util opens ANY network connection, else `net: none`
  - `secrets:` — every credential-shaped env var the code reads, or `(none)`

  The catalog is derived from this header — there is no index to edit.
- **`net:` and `secrets:` are enforcement, not documentation.** The routine-scheduler engine
  runs each util in a Landlock sandbox keyed off these two lines: `net:` decides whether TCP
  is permitted at all (undeclared = ALL TCP denied) and `secrets:` decides which credentials
  are injected (undeclared = scrubbed, even when the daemon's environment carries them). Get
  them wrong and the util works here and fails *there* — no network, or an empty credential —
  which is far harder to diagnose than a clean rejection. When in doubt about a var, declare
  it. `rsched.utils_lib.header_problems` on the server is the authoritative spec; `gu lint`
  implements the same rules, so keep the two in step if either moves.
- **I/O contract**: data on stdout (human-readable by default, JSON under `--json`);
  diagnostics and progress on stderr, never stdout; exit 0 on success, non-zero on failure.
- **`--selftest`**: at minimum one representative happy-path check against built-in fixture
  data. This is what makes later silent revision safe.
- **Composition** goes through the CLI boundary, never Python imports across utils:
  ```python
  rows = json.loads(subprocess.run(
      ["gu", "csv-dedupe", path, "--json"],
      capture_output=True, text=True, check=True,
  ).stdout)
  ```
  Note: any code string containing `gu <name>` counts as a derived call site — keep prose
  mentions of other utils in comments or the docstring, never in code strings.
- When promoting a one-off, keep the proven logic but refit it to this shape; generalize
  the hardcoded values into arguments.

## 4. Verify (all green before declaring done)
1. `gu lint <slug>` — doc-standard conformance: the six header lines, `calls:` vs the derived
   graph, and `secrets:` vs the credential env vars the source actually reads.
2. Smoke-test: `gu <slug> ...` on a real or representative input, and `gu <slug> ... --json`.
3. `gu <slug> --selftest`.

Fix and re-run until all three pass. The first `gu <slug>` run also exercises PEP 723
resolution — a typo'd dependency surfaces here.

## 5. Commit (every library write is a commit)
- `git -C LIB add -A`
- `git -C LIB commit -m "create <slug>"`

## 6. Report
There is **no index step** — the catalog is derived, and the SessionStart hook injects a
fresh snapshot at the next startup/resume/clear/compact. Report to the user:
- the slug and what it does (the one-line summary),
- the invocation (`gu <slug> ...`, plus `--json` for structured output),
- which packages it depends on (or none), and the commit message used.
