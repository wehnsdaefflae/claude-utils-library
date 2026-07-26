# Global utils library for Claude Code

A personal standard library of **composable Python CLI utilities** — called **utils** — that
Claude Code can both *build* and *use*, shared across every project and every session. Each
util is a real command, invoked through a single dispatcher:

```bash
gu heic2jpg *.heic --quality 85
gu csv-dedupe data.csv --json
```

This is the executable counterpart of the sibling
[instruction library](https://github.com/wehnsdaefflae/claude-instruction-library): that one
maintains reusable *prose*, this one maintains reusable *code*. The defining difference:
utils are cheap to be aware of (one line each), so the whole catalog is **pushed into every
session** rather than pulled on demand — an existing util competes with writing inline code
on every task.

- **Using a util needs no skill.** It's just running a command, like `jq`. A SessionStart
  hook injects a fresh `gu list` snapshot at startup/resume/clear/compact, and one durable
  pointer line in `CLAUDE.md` survives compaction as the floor that never vanishes.
- **`/create-util`** — build a new util, most often by promoting a reusable one-off script
  Claude just wrote. Claude *offers* promotion but writes to the library only on your
  explicit yes — the library never fills with half-baked utils.
- **`/revise-util [slug]`** — fix or extend a util. Also fires *implicitly*: when a util
  errors mid-use, Claude repairs it without interrupting you. Silent but reversible — the
  selftests of the util **and everything that calls it** gate the write, and every write is
  a git commit you can `git revert`.

This repository is the **single source of truth**. Editing happens here; `./deploy.sh`
copies the dispatcher, skills, and hook into your live config. Never hand-edit the deployed
copies — re-run `deploy.sh` after changing anything here.

## How it works

The library lives at `$GLOBAL_UTILS_HOME` (or the XDG default
`~/.local/share/global-utils/`) — that two-step lookup is the entire location mechanism;
there is no config file:

```
$GLOBAL_UTILS_HOME/
  .git/                  mandatory — every create/revise/remove is a commit
  gu                     the dispatcher (stdlib-only Python, symlinked onto PATH)
  utils/
    <slug>/main.py       PEP 723 deps + standard docstring + argparse + --json + --selftest
  .active/<session_id>   session → util binding for revise-util (gitignored, pruned >30d)
```

**Everything structural is derived, never hand-maintained.** There is no stored index:
`gu list` regenerates the catalog from each util's docstring header on every read. The
dependency graph comes from `gu deps`, which scans source for `gu <name>` call sites — the
`calls:` docstring line is documentation only, and `gu lint` flags any disagreement.

**The header is also a sandbox contract.** This library doubles as the util library of a
[routine-scheduler](https://github.com/wehnsdaefflae/routine-scheduler) instance, where LLM
routines run these utils inside a Landlock jail keyed off two header lines: `net:` (undeclared
= all TCP denied) and `secrets:` (only declared credentials are injected). `gu lint` enforces
both, so a util created here is one the scheduler accepts.

**Dependencies are isolated per util.** Each `main.py` declares its own deps in a PEP 723
`# /// script` header and runs via `uv run` in its own cached environment — cross-util
conflicts are impossible, yet it feels like one managed space. ([uv](https://docs.astral.sh/uv/)
is required to run utils; `gu` itself is stdlib-only.)

**Utils compose through the CLI boundary.** A util calls another as a subprocess
(`["gu", "csv-dedupe", path, "--json"]`) with structured I/O — small utils layer into bigger
ones while each stays independently testable. Those call sites *are* the composition graph;
`gu deps` derives it so `revise-util` and `gu remove` can reason about blast radius.

### The dispatcher

| Command | Behavior |
|---------|----------|
| `gu list` | The derived catalog — header read only, no execution, no venv. |
| `gu <util> [args]` | `uv run` the util in its own cached env. |
| `gu help <util>` | The util's `--help`. |
| `gu lint [<util>]` | Doc-standard conformance, incl. `calls:` vs the derived graph and `secrets:` vs the credential env vars the source reads. |
| `gu deps <util>` | What it calls and what calls it, derived from source. |
| `gu remove <util>` | Delete — refuses while anything still calls it (`--force` overrides). |
| `gu index` | Write the catalog to a gitignored `INDEX.md`, if a browsable file is wanted. |

See [SYSTEM_DESIGN.md](SYSTEM_DESIGN.md) for the full design, the settled decisions, and
walked-through use cases.

## Example workflow

A conversation excerpt showing the full lifecycle — a one-off getting promoted, then reused
weeks later, then self-healing when it hits bad input. ([SYSTEM_DESIGN.md §7](SYSTEM_DESIGN.md)
walks through every scenario.)

> **You:** Dedupe `contacts.csv` — collapse rows with the same email.
>
> **Claude:** *(writes a quick script, runs it)* Done — 1,204 rows → 1,180, dropped 24
> duplicate emails. This looks reusable; want me to promote it to `gu csv-dedupe` so it's a
> permanent command?
>
> **You:** yes
>
> **Claude:** *(runs `/create-util`)* Scaffolded `utils/csv-dedupe/main.py` to the doc standard,
> `gu lint` clean, `--selftest` passes, committed `create csv-dedupe`. Use it anywhere with:
> ```bash
> gu csv-dedupe contacts.csv --key email --json
> ```

Weeks later, in a fresh session — the catalog was pushed in at session start, so it's already
visible:

> **You:** Clean up the dupes in this export, then chart signups per month.
>
> **Claude:** `csv-dedupe` is in the catalog, so I'll use it rather than rewrite:
> ```bash
> gu csv-dedupe export.csv --key email --json
> ```
> ```
> gu: error: 'utf-16' codec can't decode byte ... (the file is UTF-16)
> ```
> That's a bug in the util — patching it instead of working around it. *(implicit
> `revise-util`: fixes the encoding handling, re-runs `gu lint`, `csv-dedupe --selftest`, **and**
> every reverse-dependent's selftest, commits `revise csv-dedupe: handle UTF-16 input`)*
> Fixed and committed — `git revert` undoes it if it was wrong. Re-running:
> ```bash
> gu csv-dedupe export.csv --key email --json   # 3,002 → 2,955
> ```
> Now for the chart.

The util got built once, reused with zero rebuild, and repaired itself mid-task — all without
leaving the conversation. Explicit edits work the same way (`/revise-util csv-dedupe — also
accept a --since filter`), and utils compose by shelling out to each other (`report` calling
`gu csv-dedupe --json` then `gu chart --json`), each in its own isolated env.

## Install (user-wide)

```bash
./deploy.sh
```

This creates the library home (git-initialized), installs `gu` (after checking for the
GraalVM `gu` collision), copies the two skills into `~/.claude/skills/`, copies the hook
into `~/.claude/hooks/` and registers it in `~/.claude/settings.json` for all four
SessionStart matchers (idempotently, preserving your existing settings), and appends the
durable pointer line to `~/.claude/CLAUDE.md`. Restart Claude Code afterwards so the hook
registration takes effect.

For a custom library location, `export GLOBAL_UTILS_HOME=...` in your shell rc *before*
deploying — the env var is the only persistence of a custom location. Relocating later is
moving the directory and updating the env var.

## Notes

- Python ≥ 3.11 (`gu` uses stdlib `tomllib`) and [uv](https://docs.astral.sh/uv/) on PATH.
- The hook stays silent while the library is empty; the catalog appears once the first util
  exists.
- Two sessions revising the same util race (last-write-wins); git makes the loser
  recoverable. See SYSTEM_DESIGN.md §8 for this and other deliberate deferrals.
- Maintaining this repo (editing the dispatcher/skills/hook, cutting a release)?
  See [CONTRIBUTING.md](CONTRIBUTING.md).
