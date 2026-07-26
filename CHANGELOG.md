# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While pre-1.0, breaking
changes are released as MINOR bumps.

## [Unreleased]

### Fixed
- **`deploy.sh` no longer commits unrelated work-in-progress.** It staged the library with
  `git add -A` and committed everything as "deploy: gu dispatcher + library scaffolding" —
  so redeploying while any util was mid-edit swept that util into a deploy commit and (since
  the library auto-pushes) published it to the shared remote, mislabelled and possibly
  unfinished. Observed doing exactly that to a 290-line in-progress `codemap` revision. Deploy
  now stages only `gu` + `.gitignore`, and prints a note that other uncommitted changes were
  left alone.

### Changed
- **The doc standard now covers `tags:`, `net:` and `secrets:` — aligned with the
  routine-scheduler, which is authoritative.** This library doubles as the util library of a
  routine-scheduler instance, and there every util subprocess runs in a Landlock sandbox keyed
  off two header lines: `net:` decides whether TCP is allowed at all (undeclared = **all TCP
  denied**) and `secrets:` decides which credentials are injected (undeclared = scrubbed). The
  server enforced all six header lines via `rsched.utils_lib.header_problems`, while `gu lint`
  and both skills still taught only three — so a util created here linted clean and then failed
  *there* with no network or an empty credential, a silent runtime failure rather than a clean
  rejection. `gu lint` now checks `tags:` (≥1), `net: outbound|none`, and `secrets:` against the
  credential-shaped env vars the source actually reads (direct `os.environ["X_TOKEN"]` and
  module-constant-indirect shapes; the scheduler additionally handles a grouped tuple-of-names
  shape). `create-util` scaffolds all six lines and states that two of them are enforcement, not
  documentation; `revise-util` gains an explicit re-check, since adding an HTTP call or a new
  credential read silently invalidates them. Verified across all 80 utils: verdicts identical to
  before (the scheduler's boot migration had already repaired every existing header), and
  confirmed to agree with `header_problems` on a deliberately broken fixture. Docs swept:
  `SYSTEM_DESIGN.md` §3.3 + lint row + UC1, `README.md`, `CLAUDE.md`.
- **Skills now pull before they write.** `/create-util` (start of the reuse check) and
  `/revise-util` (new step 0) begin with `git -C LIB pull --rebase --autostash` + a
  re-derived `gu list`. Rationale: the library auto-pushes on commit but never pulled, and
  with multiple instances sharing one remote the local catalog silently staled — leading to
  an independently created duplicate util (`deepgram`) that had to be merged out of a rebase
  conflict. Offline → proceed with a note; conflict → resolve/abort before writing.
- **Discovery guidance strengthened: "prefer a util" → "default to a util."** The SessionStart
  hook snapshot and the `CLAUDE.md` pointer now name the trigger (before writing more than a
  trivial one-liner of shell/Python), the use-an-existing-util path, *and* the
  create-when-none-exists path via `/create-util` — closing the gap where the absence of a
  matching util quietly nudged Claude toward inline code instead of creating one. `deploy.sh`
  now replaces the pointer line in place on redeploy (it previously skipped when the anchor was
  present, so reworded pointers never propagated to already-deployed machines) and collapses
  duplicates. Wording synced in `SYSTEM_DESIGN.md` (Discovery, Layer 2).
- **`/create-util`: reuse check → reuse & factoring check.** Before scaffolding, the skill now
  also decides where util boundaries fall — factor a candidate into single-responsibility utils
  composed at the CLI boundary, quarantine unreliable/heuristic steps in their own util, prefer
  a data template over code when the reusable thing is data, and extract only seams a second
  caller actually needs (YAGNI). Rationale documented in `SYSTEM_DESIGN.md` §5.1; summarized in
  `CLAUDE.md`.

## [0.1.0] - 2026-06-10

Initial implementation of the global-utils system described in `SYSTEM_DESIGN.md`.

### Added
- **`gu` dispatcher** (stdlib-only Python, Python ≥ 3.11): `list` (catalog derived live from
  each util's PEP 723 block + docstring header — no execution, no stored index), `<util>`
  (runs via `uv run --script` in the util's own cached env), `help`, `lint` (doc-standard
  conformance incl. `calls:` vs the derived graph), `deps` (dependency graph derived from
  `gu <name>` call sites in source, both list-form and shell-string subprocess calls),
  `remove` (refuses while reverse-dependents exist, `--force` to override, commits), and
  `index` (optional gitignored `INDEX.md` cache).
- **`/create-util` skill** — builds a new util (or promotes a one-off script) on explicit
  confirmation only: mandatory reuse check against a fresh `gu list` (revise or compose
  instead of duplicating), PyPI/web package research before hand-rolling non-trivial logic,
  doc-standard scaffold (PEP 723, `--json`, `--selftest`), verification via
  `gu lint` + smoke test + selftest, and a `create <slug>` commit.
- **`/revise-util` skill** — explicit changes and implicit mid-use auto-repair: blast-radius
  check in both directions of `gu deps` (including deciding whether the fix belongs in a
  callee), selftests of the target **and every reverse-dependent** gate the write, a
  `revise <slug>: <what>` commit makes it reversible, and the session is bound via
  `.active/<session_id>` (empty-`CLAUDE_SESSION_ID` guard, entries pruned after 30 days).
- **Two-layer discovery**: `hooks/inject-utils-catalog.py`, a SessionStart hook registered
  for all four matchers (`startup|resume|clear|compact`), injects a fresh `gu list` snapshot
  (the `compact` re-fire both restores the snapshot compaction destroys and refreshes it);
  plus one durable pointer line appended to the user's `CLAUDE.md` as the floor that
  survives compaction. The hook is silent for an absent or empty library and always exits 0.
- **`deploy.sh`** — first-run setup (UC7) and redeploy in one idempotent script: creates the
  library home (`$GLOBAL_UTILS_HOME` → XDG default) with a mandatory git repo, installs `gu`
  on PATH after checking for the GraalVM `gu` collision, copies skills and hook, registers
  the hook in `settings.json` preserving existing keys, and appends the `CLAUDE.md` pointer.
- **`release.sh`** — changelog-driven tagging and GitHub releases (shared with the sibling
  instruction-library repo).
- `README.md`, `CLAUDE.md`, and the pre-existing `SYSTEM_DESIGN.md` documenting the design:
  derived catalog and derived dependency graph (nothing structural is hand-maintained),
  per-util dependency isolation via PEP 723 + `uv run`, composition strictly through the
  CLI boundary, every library write a git commit, suggest-don't-auto creation, and
  silent-but-reversible revision.

[Unreleased]: https://github.com/wehnsdaefflae/claude-utils-library/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/wehnsdaefflae/claude-utils-library/releases/tag/v0.1.0
