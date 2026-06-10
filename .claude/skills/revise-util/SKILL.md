---
name: revise-util
description: Fix or extend an existing util in the global utils library. Use on explicit /revise-util <slug>, or implicitly (auto-repair) when a library util errors or misbehaves mid-use — patch it without interrupting the user; selftests gate the write and a git commit makes it reversible.
argument-hint: "[optional: slug — and/or what to change]"
allowed-tools: Read Write Edit AskUserQuestion WebSearch WebFetch Bash(gu *) Bash(git *) Bash(uv *) Bash(echo *) Bash(cat *) Bash(head *) Bash(ls *) Bash(mkdir *) Bash(printf *) Bash(find *) Bash(command *)
---

Library home (LIB): !`echo "${GLOBAL_UTILS_HOME:-$HOME/.local/share/global-utils}"`
Bound util for this session (empty if none): !`cat "${GLOBAL_UTILS_HOME:-$HOME/.local/share/global-utils}/.active/${CLAUDE_SESSION_ID}" 2>/dev/null || true`
Fresh catalog — the source of truth; any in-context snapshot may be stale:
!`gu list 2>&1 || true`

Directive (optional): `$ARGUMENTS`

Call that library path **LIB**. You are changing shared code that every project and every
other util may rely on — the procedure below is what makes a *silent* revision acceptable:
verified by selftests, recorded as a commit, always revertible.

## 1. Resolve the target util
- A slug in `$ARGUMENTS` that appears in the catalog wins.
- Otherwise use the bound util above, if non-empty — but clear a **stale binding** (slug no
  longer in the catalog) with
  `find "$LIB/.active" -name "${CLAUDE_SESSION_ID}" -delete` and fall through.
- Otherwise infer from context (the util that just erred, or the one the conversation is
  about). If genuinely ambiguous, ask (AskUserQuestion with the plausible candidates).

## 2. Blast radius — check BOTH directions before editing
Run `gu deps <slug>`. This graph is **derived from call sites in source** — trust it over
any `calls:` docstring line.
- **Reverse-dependents** (what calls this util): the revision must not break the util's
  contract as an element inside them — changed flags, output shape, or exit semantics
  propagate. Read how each caller invokes it.
- **Callees** (what this util calls): if the revision changes a call into a callee, the
  callee's contract bounds the change. And sometimes the right fix belongs *in the callee* —
  where every other caller benefits — not in the target. Decide the fix's home before
  editing; if it moves, the callee becomes the revise target and this whole procedure
  applies to *its* reverse-dependents.

## 3. Edit `LIB/utils/<slug>/main.py`
Keep it conforming to the doc standard: PEP 723 deps (add a package here if the fix needs
one — prefer an established package over hand-rolling, per-util isolation makes it
near-free), the docstring header (summary / `usage:` / `calls:` — update `calls:` if the
call sites changed), `--json`, `--selftest`, and the I/O contract (data on stdout,
diagnostics on stderr, meaningful exit codes). Extend the selftest when the revision adds
behavior — the fixture that would have caught this bug belongs in it now.

## 4. Verify (the gate for every revision, explicit or implicit)
1. `gu lint <slug>`
2. `gu <slug> --selftest`
3. `gu <dependent> --selftest` for **every** reverse-dependent from step 2 — a fix for
   input X that breaks caller Y is caught here, not weeks later.
4. Re-run the invocation that originally failed (implicit revise) or exercises the new
   behavior (explicit revise).

All green before the write counts as done. If a reverse-dependent's selftest breaks and the
fix is genuinely incompatible with it, stop and surface the conflict to the user instead of
forcing either side.

## 5. Commit (what makes silent revision reversible)
- `git -C LIB add -A`
- `git -C LIB commit -m "revise <slug>: <one line — what changed>"`

## 6. Bind the session & housekeeping
So a follow-up revise needs no slug — **only if `${CLAUDE_SESSION_ID}` is non-empty**;
never write a `.active/` file with an empty name:
- `mkdir -p "$LIB/.active"`
- `printf '%s\n' '<slug>' > "$LIB/.active/${CLAUDE_SESSION_ID}"`
- Prune stale bindings: `find "$LIB/.active" -type f -mtime +30 -delete 2>/dev/null || true`

## 7. Report
Tell the user what changed and which selftests passed (target + reverse-dependents). For an
**implicit** revise, say explicitly that a library util was repaired mid-task — e.g.
*"csv-dedupe choked on UTF-16; fixed in the library (commit `revise csv-dedupe: handle
UTF-16 input`), selftests for csv-dedupe and report pass"* — so the silent write is never
invisible, and `git -C LIB revert` undoes it if the fix was wrong.
