# Project: global-utils system

A user-wide library of composable Python CLI **utils** that Claude can build and use, living
at `$GLOBAL_UTILS_HOME` (default `~/.local/share/global-utils/`) and dispatched through `gu`.
This repo is the single source of truth for the dispatcher + skills + hook; `./deploy.sh`
copies them into the library home and `~/.claude/` — never hand-edit the deployed copies.

Workflow:
- **Using a util needs no skill** — `gu <name> [args]` is just a command. Discovery is
  push-based: a SessionStart hook (matchers `startup|resume|clear|compact`) injects a fresh
  `gu list` snapshot, and a durable pointer line in the user's `CLAUDE.md` survives
  compaction.
- **`/create-util`** — new util, usually promoting a one-off script. Suggest, never silent:
  writes only on the user's explicit yes. Reuse check (fresh `gu list` + `gu deps`) before
  creating; PyPI research before hand-rolling non-trivial logic.
- **`/revise-util [slug]`** — explicit changes, *and* implicit auto-repair when a util errors
  mid-use. Gated by `gu lint` + the target's `--selftest` + every reverse-dependent's
  `--selftest`; every write is a git commit (silent but reversible).

Key design facts (full rationale in SYSTEM_DESIGN.md):
- **Everything structural is derived.** No stored index — `gu list` reads each util's
  docstring header live. The dependency graph comes from `gu deps` scanning source for
  `gu <name>` call sites; the `calls:` docstring line is documentation only (`gu lint`
  keeps it honest).
- **Doc standard** (every `utils/<slug>/main.py`): PEP 723 `# /// script` deps block;
  docstring first line `<slug> — <summary>` (em dash) + `usage:` + `calls:` lines; argparse
  with `--json` and `--selftest`; data on stdout, diagnostics on stderr, meaningful exit
  codes.
- **Per-util dependency isolation** via PEP 723 + `uv run`; utils compose only through the
  CLI boundary (`["gu", "<name>", ..., "--json"]` subprocesses), never Python imports.
- **`gu` is stdlib-only** — it bootstraps everything else, so it cannot depend on anything
  it manages. Requires Python ≥ 3.11 (`tomllib`).
- **Location resolution** is `$GLOBAL_UTILS_HOME` → XDG default, nothing else — never add a
  pointer/config file inside the library home (it cannot bootstrap its own discovery).
- **The library home is a git repo, non-optionally**; create/revise/remove each end in a
  commit (`create <slug>`, `revise <slug>: <what>`, `remove <slug>`).
- Session → util bindings live in `.active/<session_id>` (gitignored, pruned >30 days,
  guarded against empty `CLAUDE_SESSION_ID`).
