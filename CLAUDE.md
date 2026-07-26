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
  writes only on the user's explicit yes. Reuse & factoring check (fresh `gu list` + `gu deps`)
  before creating — reuse/compose existing utils, *and* decide whether the candidate should be
  split into single-responsibility utils (quarantine flaky steps; data→template, not code;
  YAGNI on unproven seams, see SYSTEM_DESIGN §5.1); PyPI research before hand-rolling non-trivial
  logic.
- **`/revise-util [slug]`** — explicit changes, *and* implicit auto-repair when a util errors
  mid-use. Gated by `gu lint` + the target's `--selftest` + every reverse-dependent's
  `--selftest`; every write is a git commit (silent but reversible).

Key design facts (full rationale in SYSTEM_DESIGN.md):
- **Everything structural is derived.** No stored index — `gu list` reads each util's
  docstring header live. The dependency graph comes from `gu deps` scanning source for
  `gu <name>` call sites; the `calls:` docstring line is documentation only (`gu lint`
  keeps it honest).
- **Doc standard** (every `utils/<slug>/main.py`): PEP 723 `# /// script` deps block;
  docstring first line `<slug> — <summary>` (em dash) + `usage:` + `calls:` + `tags:` +
  `net:` + `secrets:` lines; argparse with `--json` and `--selftest`; data on stdout,
  diagnostics on stderr, meaningful exit codes.
- **`net:` and `secrets:` are enforcement, shared with the routine-scheduler.** That instance
  runs these utils in a Landlock sandbox keyed off the two lines: `net: none` (or undeclared)
  denies ALL TCP, and only credentials named on `secrets:` are injected. Omitting them yields
  a util that lints clean here and fails on the server with no network or an empty credential.
  `rsched.utils_lib.header_problems` is the authoritative spec; `gu lint` mirrors it — **if
  either moves, move the other.**
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
