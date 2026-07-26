# global-utils — Design

A system of Claude Code skills for generating and using **user-wide, composable Python
command-line utilities** that live in one shared user space and grow more capable over time.

Each unit is called a **util**. Utils are invoked through a single dispatcher, `gu`. The
library is shared across every project and every session — it is a personal standard library
of CLIs that Claude can both *build* and *use*.

---

## 1. Motivation & guiding principles

The user already has a sibling system — `save-instruction` / `use-instruction` — that maintains
a **library of reusable prose instructions**. This is its executable counterpart: a **library of
reusable code**. The two share a skeleton (a global library, session binding, fold-corrections-
back-in) but differ on one axis that drives the entire design:

> **Instructions** are expensive to load and you want *exactly one* active at a time → explicit
> single-pick pull.
> **Utils** are cheap to be *aware* of (a name + one-liner + invocation) and you want Claude to
> know about *all* of them so it picks the right one → push the catalog into every session, don't
> wait to be asked.

Principles that follow from that and from the design decisions made:

1. **Utils are real CLI commands.** "Using" a util needs no skill — it is just running a command,
   like `jq`. Skills exist only for *building* and *revising*.
2. **One shared library, isolated per-util dependencies.** Dependency conflicts between utils are
   impossible (PEP 723 + `uv run`), yet it still feels like one managed space.
3. **Utils compose through the CLI boundary.** A util calls another util via `gu <name>` as a
   subprocess with structured I/O. Small utils layer into bigger ones. Complexity grows by
   composition, not by a monolith — boundaries drawn at creation time by factoring along
   responsibilities (§5.1).
4. **Everything structural is derived, never hand-maintained.** The catalog is regenerated from
   the doc standard on every read; the dependency graph is derived from the call sites in source,
   not from declarations. Nothing a safety check relies on can drift.
5. **Creation is suggested, never silent. Revision is silent but reversible.** Claude offers to
   promote a reusable one-off into a util but writes to the library only on explicit confirmation
   — the library stays clean. Mid-task auto-repair of an *existing* util does not interrupt the
   user; instead, every library write is a git commit and every util carries a selftest, so a
   silent revision is always verified and always rollback-able.
6. **Location is discovered, not hardcoded** — through exactly one mechanism (an environment
   variable with an XDG fallback), never a pointer file that lives inside the directory it is
   supposed to locate.

---

## 2. Settled design decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Dependency model | **PEP 723 inline deps + `uv run`** | Each util declares its own deps in a `# /// script` header; uv caches/reuses an env per util. Feels like one shared library; cross-util conflicts impossible. |
| Library location | **`$GLOBAL_UTILS_HOME` → XDG `~/.local/share/global-utils/`** | Two-step resolution, no config file. A pointer file inside the home cannot bootstrap discovery of the home (circular); custom locations are served by persisting the env var in the shell rc. |
| Unit noun | **util** | "tool" is overloaded (Claude tools, MCP tools, slash commands). "util" is accurate, collision-free, and scales from a 10-line script to a large composite. |
| Dispatcher | **`gu`** (global utils), **stdlib-only Python** | Short, on PATH, callable from inside any util (enables composition). Zero dependencies — it bootstraps everything else, so it cannot depend on anything it manages. Setup checks `command -v gu` first (GraalVM also ships a `gu`). |
| Composition | **CLI boundary, structured I/O** | `gu other --json` as a subprocess. Respects per-util dependency isolation; Unix-pipe model. |
| Catalog | **Derived from a doc standard** (`gu list` regenerates) | No `index.md` to maintain or drift. A util's summary lives inside the util. |
| Dependency graph | **Derived from source** (`gu deps` finds `gu <name>` call sites) | The graph feeds safety checks (blast radius, removal), so it must not be hand-maintained. The `calls:` docstring line is documentation only; `gu lint` keeps it honest. |
| Discovery | **Two layers: SessionStart hook (matchers `startup`, `resume`, `clear`, `compact`) injects a fresh `gu list` snapshot; one durable pointer line in `CLAUDE.md`** | Push, not pull — with the catalog already in context, an existing util competes with inline code on every task. The `compact` matcher matters twice: hook-injected context does not survive compaction (the snapshot would vanish), and the re-fire runs `gu list` fresh (mid-session changes surface). The `CLAUDE.md` line survives compaction as standing context — the floor that never vanishes. |
| Versioning | **The library is a git repo — mandatory.** Every create / revise / remove auto-commits with a generated message. | The cheapest insurance in the design: it is what makes *silent* revision (principle 5) acceptable — auditable and reversible. |
| Testing | **Every util carries `--selftest`** | Revise runs it on the target *and its reverse-dependents*. Auto-repair of shared code without tests is the dangerous quadrant; even smoke-level selftests catch "fix for X broke Y". |
| Create trigger | **Suggest, never auto-write** | Proactive offer to promote a reusable one-off; writes only on explicit yes. |
| Reuse before create | **Mandatory overlap check** (`gu list` fresh + `gu deps`) | Creation starts by checking whether an existing util already covers the need (→ revise it) or covers sub-parts (→ compose via `gu <name>`). Dedup by procedure, not just ambient catalog awareness. |
| Packages before hand-rolling | **Research PyPI/web first** | Per-util isolation makes a dependency near-free, so the bar for reimplementing solved problems is high. Search for an established package before writing non-trivial logic. |
| Revise trigger | **Explicit + implicit** | `/revise-util <slug>` for deliberate change; auto-repair when a util errors mid-use, folding the fix back (verified by selftests, recorded as a commit). |

---

## 3. Architecture

### 3.1 Directory layout

```
$GLOBAL_UTILS_HOME/            # resolved location (see §3.2)
  .git/                       # mandatory — every library write is a commit (see §3.6)
  gu                          # the dispatcher (stdlib-only Python, on PATH)
  utils/
    heic2jpg/
      main.py                 # PEP 723 header + standard docstring + argparse + --json + --selftest
    csv-dedupe/
      main.py
    report/
      main.py                 # composite: calls `gu csv-dedupe`, `gu chart` as subprocesses
  .active/
    <session_id>              # session → util binding, used by revise-util; entries older
                              # than ~30 days are pruned opportunistically
```

There is **no** `index.md` (the catalog is produced on demand by `gu list`, see §3.4) and **no**
`config.toml` (location resolution needs no state, see §3.2).

### 3.2 Location resolution

The dispatcher and both skills resolve the library home in this order:

1. `$GLOBAL_UTILS_HOME` environment variable, if set.
2. XDG default: `~/.local/share/global-utils/`.

That is the whole algorithm. First-run setup (UC7) creates the XDG default — or the env var's
target if one is set — but never records the location in a file. A config file inside the home
cannot bootstrap discovery of the home: you would need to know the location to find the file
that tells you the location. A user who wants the library somewhere custom (e.g. inside a synced
git-repos directory) exports `GLOBAL_UTILS_HOME` in their shell rc; setup offers to append that
line.

### 3.3 The doc standard (every util conforms)

The top of every util's `main.py` is a fixed, machine-readable shape. This is what makes the
catalog regenerable and makes utils self-describing:

```python
# /// script
# dependencies = ["pillow"]
# ///
"""heic2jpg — convert HEIC images to JPG.

usage: gu heic2jpg <files...> [--quality N] [--json]
calls: (none)
tags: images, conversion
net: none
secrets: (none)
"""

import argparse, json, sys
# ...
```

- **PEP 723 block** (`# /// script ... # ///`): the util's own dependencies. `uv run` resolves
  and caches an environment from this — isolated from every other util.
- **Docstring first line**: `name — one-line summary`. This *is* the catalog entry.
- **`usage:` line**: the invocation contract.
- **`calls:` line**: which other utils this one invokes (or `(none)`). *Documentation only* —
  the authoritative dependency graph is derived from source by `gu deps` (§3.4), and `gu lint`
  flags any disagreement between the two.
- **`tags:` line**: at least one comma-separated tag, for grouping and search.
- **`net:` line**: `outbound` if the util opens any network connection, else `none`.
- **`secrets:` line**: every credential-shaped env var the code reads, or `(none)`.
  `gu lint` scans the source for credential-shaped env reads and flags any the line omits.
- **The I/O contract** (composition lives or dies on this discipline):
  - data on **stdout** — human-readable by default, structured JSON under `--json`;
  - diagnostics and progress on **stderr**, never stdout;
  - exit code `0` on success, non-zero on failure.
- **`--selftest` mode**: the util runs its own checks (at minimum: a representative happy-path
  invocation against built-in fixture data) and exits 0/non-zero. This is what makes silent
  revision safe (§4.2) — every revise must leave the target's selftest *and* its
  reverse-dependents' selftests green.

Conformance is enforced, not assumed: `create-util` and `revise-util` run `gu lint` before
declaring done, and `gu list` warns loudly about nonconforming utils instead of silently
dropping them from the catalog.

**`net:` and `secrets:` are a security contract with a second consumer.** This library is also
the util library of the *routine-scheduler* instance, where LLM-driven routines invoke these
same utils — and there every util subprocess runs inside a Landlock sandbox keyed off exactly
those two lines: `net:` decides whether TCP is permitted at all (undeclared = **all TCP
denied**, fail closed), and `secrets:` decides which credentials are injected (undeclared =
scrubbed, even when the daemon's own environment carries them). A util that omits them is not
merely under-documented — it lints clean on a workstation and then fails on the server with no
network or an empty credential, which is markedly harder to diagnose than a clean rejection.
`rsched.utils_lib.header_problems` is the authoritative spec for the header; `gu lint`
implements the same rule set so the two gates agree. **If either moves, move the other** — a
util created here must be one the scheduler accepts.

### 3.4 The `gu` dispatcher

`gu` is the entire "use" mechanism. Running utils requires no skill. It is a single stdlib-only
Python script — it bootstraps everything else, so it cannot depend on anything it manages.

| Command | Behavior |
|---------|----------|
| `gu list` | Glob `utils/*/main.py`, read the PEP 723 deps + docstring header (first ~15 lines, **no execution, no venv**), print the catalog fresh. This *is* the index — derived, never stored. Nonconforming utils produce a loud warning line, not a silent omission. |
| `gu <util> [args]` | `uv run utils/<util>/main.py [args]` — runs the util in its own cached env. |
| `gu help <util>` | The util's `--help`. |
| `gu lint [<util>]` | Doc-standard conformance: PEP 723 header parses, docstring shape (summary / `usage:` / `calls:` / `tags:` / `net:` / `secrets:`), `--json` and `--selftest` present, the `calls:` line matches the derived graph, and the `secrets:` line covers every credential-shaped env var the source reads. No util, lint everything. |
| `gu deps <util>` | The derived dependency graph: what `<util>` calls and what calls it, found by scanning `utils/*/main.py` for `gu <name>` subprocess call sites. Feeds blast-radius checks in `revise-util` and removal safety. |
| `gu remove <util>` | Delete a util — but first check reverse-dependents via the derived graph and refuse if anything still calls it (`--force` to override). Commits the removal. |
| `gu index` | (optional) Same data as `gu list`, written to a file if a cached `INDEX.md` is ever wanted. The harness never needs it. |

Because `gu` is on PATH, **any util can call any other util** as a subprocess — this is how
composition and growing complexity work (see §5).

### 3.5 Discovery (always-on, push not pull)

Discovery has to survive two things a naive "inject once at session start" misses: **the
context can be compacted** (hook-injected content does not survive compaction — the catalog
would silently vanish mid-session) and **the util set can change during a session** (this
session promotes a one-off; a concurrent session adds or revises something). So discovery is
two-layered:

**Layer 1 — fresh snapshot (hook).** A **SessionStart hook**, registered for all four matchers
(`startup`, `resume`, `clear`, `compact`), runs `gu list` and injects the catalog. Each util
costs one line — exactly the "cheap to be aware of" budget from §1. The `compact` matcher does
double duty: it re-injects the catalog at precisely the moment the old copy is lost to
compaction, and because the re-fire runs `gu list` *fresh*, every compaction is also a refresh
— utils created or revised since session start appear in the new snapshot.

**Layer 2 — durable pointer (`CLAUDE.md`).** One line in the user's `CLAUDE.md`:

> Reusable CLI utils live in a global library (run `gu list` for the current set; the
> in-context catalog is a snapshot). Default to a util over inline code: before writing more
> than a trivial one-liner of shell or Python, use a util that fits, or create one with the
> create-util skill when the need is reusable and none exists.

`CLAUDE.md` survives compaction as standing context, so this line is the floor that never
vanishes: even when the snapshot is stale or momentarily absent, Claude always knows the
library exists and how to query it.

The snapshot is a cache; **`gu list` is the source of truth.** The injected output opens with a
header saying so ("catalog snapshot — run `gu list` for current state"). The remaining
staleness window — changes between compaction points — is benign: changes made by *this*
session are in recent context anyway (Claude just ran `create-util`), and changes from a
concurrent session surface at the next compact/resume, or whenever Claude re-runs `gu list`
via the pointer.

Why a hook at all, and not the pointer alone: a pointer is pull — Claude only sees the catalog
if it decides to check, and the moment it most needs to (a task it could solve with a quick
inline script) is exactly the moment it is least likely to think of it. With the catalog
already present, an existing util competes with writing inline code on every single task.
(The third option — re-injecting on every prompt via `UserPromptSubmit` — is maximally fresh
but pays the catalog cost on every turn to close a gap layer 2 already covers; rejected at
personal-library scale.)

First-run setup (UC7) installs both layers.

This also means there is **no `use-utils` skill**: always-on injection does its entire job.

### 3.6 Every write is a commit

The library home is a git repository, non-optionally (`git init` happens in first-run setup).
`create-util`, `revise-util`, and `gu remove` each end with an auto-commit carrying a generated
message (`create csv-dedupe`, `revise csv-dedupe: handle UTF-16 input`, …).

This is what cashes the "revision is silent but reversible" half of principle 5: an implicit
mid-task repair never interrupts the user, but it is always auditable (`git log`) and always
rollback-able (`git revert`). It also gives sync (push to a private remote) for free.

---

## 4. The two skills

### 4.1 `create-util` — build a new util (explicit; suggest-don't-auto)

**Trigger:** explicit `/create-util`, or Claude *offers* it after writing a reusable one-off.

**Behavior:**
1. Resolve the library home (run first-run setup if needed, see UC7).
2. **Reuse & factoring check (before writing anything):** run `gu list` fresh (the in-context
   snapshot may be stale) and scan for overlap, then decide where the util boundaries fall.
   - If an existing util already covers the core need (or would with a modest extension),
     propose `revise-util` on it instead of creating a near-duplicate — the library stays
     deduplicated by procedure, not just by ambient awareness.
   - If existing utils cover *sub-parts* of the need, compose them: call `gu <name> --json`
     as subprocesses (§5) rather than reimplementing their logic inline.
   - If the candidate itself bundles separable responsibilities, factor it into
     single-responsibility utils — quarantining unreliable/heuristic steps, preferring a data
     template over code where the reusable thing is data, and splitting only seams a second
     caller actually needs (YAGNI). See §5.1.
3. **Package research (before hand-rolling non-trivial logic):** search PyPI / the web for an
   established, well-maintained package that already solves the core problem (e.g.
   `charset-normalizer` over hand-written encoding detection). Prefer adding it to the util's
   PEP 723 header over reimplementing — per-util isolation (`uv run`) makes the marginal cost
   of a dependency near zero, so the bar for "just write it myself" should be high. Skip the
   search only for logic that is genuinely trivial or stdlib-obvious.
4. Pick a kebab-case slug; scaffold `utils/<slug>/main.py` conforming to the doc standard:
   PEP 723 deps, standard docstring (summary / `usage:` / `calls:` / `tags:` / `net:` /
   `secrets:`), `argparse`, the `--json` structured-output mode, and a `--selftest` with at
   least one fixture-backed check.
5. Verify: `gu lint <slug>`, smoke-test via `gu <slug>` (and `gu <slug> --json`), and run
   `gu <slug> --selftest` — all green before declaring done.
6. Commit (`create <slug>`).
7. **No index step** — the catalog is derived; the new util is in this session's recent context
   already, and the hook injects a fresh snapshot at the next startup/resume/compact.
8. Report the slug, what it does, and its invocation.

**Highest-value path — promotion from a one-off:** `create-util` accepts "turn the script I just
wrote into a util." This is the most common and most valuable creation route. Claude proactively
suggests it when it notices it has written a clearly-reusable throwaway script — but **only writes
to the library on the user's explicit yes**. No silent creation; the library never fills with
half-baked utils.

### 4.2 `revise-util` — fix / extend a util (explicit + implicit)

**Explicit:** `/revise-util <slug>` for deliberate changes ("also accept PNG output").

**Implicit (the important half):** when Claude runs a library util via `gu` and it errors or
misbehaves, it fixes `main.py`, re-verifies, folds the fix back into the library as a commit, and
reports the change — mirroring how `save-instruction` absorbs mid-conversation corrections.
Silent-but-reversible: the user is not interrupted, but selftests gate the write and the commit
makes it auditable and revertible.

**Behavior:**
1. Resolve the target util. Use the session binding in `.active/<session_id>` if present
   (so a follow-up revise needs no slug); otherwise infer from context or ask.
2. Check **both directions** of `gu deps <slug>` — the *derived* graph, not the `calls:`
   docstrings — before changing anything:
   - **Reverse-dependents** (what calls this util): the blast radius. The revision must not
     break the util's contract as an element inside other utils.
   - **Callees** (what this util calls): read how they are invoked. If the revision changes a
     call into a callee, the callee's contract bounds the change; and sometimes the right fix
     belongs *in the callee* (where every other caller benefits), not in the target — decide
     the fix's home before editing.
3. Edit `main.py`, keep it conforming (`gu lint <slug>`), then verify: the target's
   `--selftest` **and the `--selftest` of every reverse-dependent** must pass. A fix for input X
   that breaks caller Y is caught here, not weeks later. (Callees are exercised transitively by
   the target's selftest; if the fix landed in a callee instead, that callee becomes the revise
   target and this step applies to *its* reverse-dependents.)
4. Commit (`revise <slug>: <what changed>`).
5. Persist the session→util binding so further revises in the session target the same util;
   opportunistically prune `.active/` entries older than ~30 days.
6. Report what changed (and, for implicit revises, that it happened).

**Session binding** uses the same trick as the instruction library:
`printf '%s\n' '<slug>' > "$GLOBAL_UTILS_HOME/.active/${CLAUDE_SESSION_ID}"`.
The skill must verify `CLAUDE_SESSION_ID` is actually set in its execution context; if not, it
falls back to inferring the target from context or asking for the slug.

---

## 5. Composability

Utils compose through the **CLI boundary**, not Python imports. A util calls another via `gu`,
as a subprocess, with structured (JSON) I/O:

```python
# inside utils/report/main.py
import json, subprocess

rows = json.loads(
    subprocess.run(
        ["gu", "csv-dedupe", path, "--json"],
        capture_output=True, text=True, check=True,
    ).stdout
)
```

Why this boundary is the right one under PEP 723:

- **Dependency isolation is preserved.** A composite util can call a pandas-heavy util and a
  pillow-heavy util without their dependency sets ever meeting — each runs in its own `uv run`
  environment.
- **`gu` is always on PATH**, so any util reaches any other regardless of which ephemeral env it
  is running in.
- **Complexity grows by layering.** Small, single-purpose utils combine into larger ones —
  exactly the "more and more complex over time" goal — while each piece stays independently
  testable and replaceable.

The enabling design rule: **every util obeys the I/O contract** (§3.3 — data on stdout, `--json`
for structure, diagnostics on stderr, meaningful exit codes), so utils are pipeable into each
other and into Claude. These `["gu", "<name>", ...]` call sites *are* the composition graph:
`gu deps` derives it from source so `revise-util` and `gu remove` can reason about blast radius,
while the `calls:` docstring line documents it for human readers (`gu lint` keeps the two
consistent).

### 5.1 Decomposition at creation time

Composition (above) is the *runtime* mechanism; the matching *authoring* decision is **where to
draw a util's boundaries** — made in `create-util` step 1, alongside the reuse check. The reuse
check asks "is this already a util?"; this asks "should this be *one* util at all?" Both guard
the same goal — small, independently testable, replaceable pieces — from opposite directions:

- **Factor by responsibility.** A candidate that bundles separable concerns — a pure
  deterministic transform, side-effecting I/O, a flaky heuristic, an orchestration layer —
  becomes several single-purpose utils, not a monolith. Splitting a new util is preferred as
  readily as not duplicating an existing one.
- **Quarantine the unreliable.** An OCR/layout guess, a scrape, any heuristic lives in its own
  util, so its flakiness cannot contaminate a deterministic core and it can be selftested,
  revised, or swapped on its own. (Concretely: a `pdf-detect-fields` guesser kept apart from a
  deterministic `pdf-stamp` placer.)
- **Data is not code.** When the reusable thing is data — coordinates for a recurring form, a
  mapping table — the artifact is a saved spec/template consumed by a *generic* util, built
  once, not a new util per instance.
- **YAGNI brake.** Extract only the seams *proven* reusable; the rest are named as future seams
  in a docstring, not speculatively split. Decomposition is a factoring judgement, and like the
  reuse and package-research checks it has a cost ceiling — it must not tip into over-building.

---

## 6. How this differs from the instruction library (and why)

| | instruction lib | util lib |
|---|---|---|
| unit | prose spec | executable CLI |
| "use" | explicit single pick (`/use-instruction`) | always-on: hook injects a fresh catalog snapshot at startup/resume/clear/compact + durable `CLAUDE.md` pointer |
| awareness cost | load one in full | one line each, all visible, every session |
| catalog | derived from front-matter on read; no stored index | derived from docstring headers on read; no stored index |
| skills | save + use | create + revise (no "use" skill needed) |
| revise trigger | `/save-instruction` after success | explicit **+** auto-repair on error (selftest-gated, committed) |
| composition | n/a | utils call utils via `gu`; graph derived from source |
| home | `~/.claude/.INSTRUCTIONS` | `$GLOBAL_UTILS_HOME` → XDG default |

> **Convergence note.** Since this design was written, the instruction library has adopted two of
> its ideas — the **derived catalog** and **mandatory git versioning**. The `index.md` it used to
> hand-maintain is gone; its catalog is now read from each instruction's front matter, exactly as
> `gu list` reads each util's docstring header. So the *catalog* row above no longer marks a
> difference but a **shared mechanism**: a structured per-unit header, derived on read, no stored
> index — differing only in header format (YAML front matter vs. PEP 723 docstring). The live
> difference that remains is **surfacing**: the util catalog is *pushed* into every session by a
> hook, while the instruction catalog is *pulled* on demand when a skill runs (the "use" row). That
> the sibling system converged on these mechanisms independently is some evidence they were the
> right calls.

---

## 7. Use cases (walked through)

### UC1 — One-off becomes a util (promotion)
> *"Dedupe this CSV."*

Claude writes a quick script, runs it, then notices it is reusable and **offers**:
*"This looks reusable — promote it to `gu csv-dedupe`?"* On **yes**, `create-util` scaffolds
`utils/csv-dedupe/main.py` to the doc standard (PEP 723, docstring, argparse, `--json`,
`--selftest`), verifies via `gu lint` + smoke test + selftest, commits, and reports the
invocation. On **no**, nothing is written.

### UC2 — Recurring task, no rebuild
> *(weeks later)* "Convert these HEIC files to jpg."

The session-start hook already injected the catalog, so Claude *sees* `heic2jpg` without doing
anything, and calls `gu heic2jpg *.heic`. No skill, no lookup step, no rebuild — the util was in
context before the request arrived.

### UC3 — Util breaks on new input (implicit revise)
> `gu csv-dedupe` chokes on a UTF-16 file.

Claude (implicit `revise-util`) patches the encoding handling in `main.py`, then verifies:
`gu lint`, `csv-dedupe --selftest`, **and** `report --selftest` (the derived graph says `report`
calls `csv-dedupe`, so the fix must not break it). All green → commit
(`revise csv-dedupe: handle UTF-16 input`) and report: *"csv-dedupe now handles UTF-16;
selftests for csv-dedupe and report pass."* No explicit command needed; `git revert` undoes it
if the fix was wrong.

### UC4 — Explicit extension
> "/revise-util heic2jpg — also accept PNG output."

Targeted change: edit `main.py`, keep it doc-standard-conforming, re-verify, commit, report. The
session is now bound to `heic2jpg`, so a follow-up *"also strip EXIF"* needs no slug.

### UC5 — Composite util grows from small ones
> "Build me a weekly report from these CSVs."

A new `report` util calls `gu csv-dedupe --json` then `gu chart --json`, each running in its own
isolated env. Small utils layer into a bigger one; the call sites *are* the graph (`gu deps`
derives it; the `calls:` line documents it). Later, fixing `csv-dedupe` (UC3) benefits `report`
for free — and `report`'s selftest guards against the fix breaking it.

### UC6 — New dependency
> A util needs `pandas`.

`create-util` / `revise-util` adds `pandas` to that util's PEP 723 header. `uv run` resolves and
caches it on next call. No shared environment is touched; no other util is affected. When the
right package is *not* already obvious, the package-research step (§4.1 step 3) finds it — the
spec's default is "search for an established package" rather than "hand-roll and hope".

### UC7 — First-run setup
> The very first `/create-util` on a fresh machine.

No `$GLOBAL_UTILS_HOME` and no XDG dir yet → setup:
1. Creates the home (the env var's target if set, else the XDG default) and runs `git init`.
2. Installs the `gu` dispatcher on PATH — after checking `command -v gu` for collisions
   (GraalVM ships a `gu`; if found, offer an alternative name or PATH priority).
3. Installs both discovery layers (§3.5): the SessionStart hook registered for all four
   matchers (`startup`, `resume`, `clear`, `compact`), and the durable pointer line in the
   user's `CLAUDE.md`.
4. If the user chose a custom location, offers to append `export GLOBAL_UTILS_HOME=…` to the
   shell rc — the env var is the *only* persistence of a custom location (§3.2).

Subsequent runs resolve instantly. Relocating later = move the directory + update the env var.

---

## 8. Open / future considerations

- **Cached `INDEX.md`:** not needed by the harness (the hook runs `gu list`), but `gu index` can
  emit one if a human-browsable file is ever wanted.
- **Catalog scale:** at hundreds of utils, injecting the full catalog every session stops being
  cheap. If that day comes: `gu list --grep <term>`, categories in the docstring standard, or a
  tiered hook (inject names only, fetch summaries on demand).
- **Selftest depth:** `--selftest` is deliberately smoke-level (fixture in, expected shape out).
  If utils grow genuinely complex, a sibling `test.py` with real cases can supplement it without
  changing the contract.
- **Concurrent sessions:** two sessions revising the same util race (last-write-wins). Git makes
  the loser recoverable; a `.lock` per util could prevent it outright if it ever happens in
  practice.
- **Windows:** `subprocess.run(["gu", ...])` and the PATH install assume POSIX. A `gu.cmd` shim
  and `%LOCALAPPDATA%` location default would be needed; out of scope until a Windows machine
  exists.
- **Sync:** the mandatory git repo makes syncing trivial (add a private remote, push after
  commit) — whether auto-push should be on by default is undecided.
