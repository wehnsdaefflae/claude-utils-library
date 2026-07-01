#!/usr/bin/env bash
# Deploy the global-utils system from this repo (the single source of truth) into the
# user's live Claude Code config and library home. This IS first-run setup (UC7) and is
# idempotent — re-run after editing anything in the repo; never hand-edit deployed copies.
#
# Honors $GLOBAL_UTILS_HOME for a custom library location (persist it in your shell rc —
# the env var is the ONLY persistence of a custom location; there is no config file).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE="$HOME/.claude"
LIB="${GLOBAL_UTILS_HOME:-$HOME/.local/share/global-utils}"

echo "Deploying from: $REPO"
echo "Library home:   $LIB"

# 1. Library home — created, git-initialized (mandatory: every library write is a commit)
mkdir -p "$LIB/utils" "$LIB/.active"
if ! git -C "$LIB" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$LIB" init -q
  printf '%s\n' '.active/' 'INDEX.md' > "$LIB/.gitignore"
  echo "  library git repo initialized at $LIB"
fi

# 2. Dispatcher — canonical copy lives inside the library home
cp -f "$REPO/gu" "$LIB/gu"
chmod +x "$LIB/gu"
echo "  gu     -> $LIB/gu"
if [ -n "$(git -C "$LIB" status --porcelain)" ]; then
  git -C "$LIB" add -A
  if git -C "$LIB" commit -qm "deploy: gu dispatcher + library scaffolding"; then
    echo "  library changes committed"
  else
    echo "  WARNING: commit failed (is git user.name/user.email configured?) — changes left staged"
  fi
fi

# 3. Put gu on PATH — checking for a collision first (GraalVM also ships a `gu`)
mkdir -p "$HOME/.local/bin"
EXISTING="$(command -v gu 2>/dev/null || true)"
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$HOME/.local/bin/gu" ]; then
  echo "  WARNING: a different 'gu' is already on PATH ($EXISTING — GraalVM ships one)."
  echo "           Not installing the symlink. Resolve the collision (remove it, reorder"
  echo "           PATH, or pick another name) and re-run deploy.sh."
else
  ln -sf "$LIB/gu" "$HOME/.local/bin/gu"
  echo "  gu     -> $HOME/.local/bin/gu (symlink)"
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "  WARNING: $HOME/.local/bin is not on PATH — add it in your shell rc." ;;
esac

# 4. Skills — copy (not symlink) into ~/.claude/skills/<name>/SKILL.md
for skill in create-util revise-util; do
  src="$REPO/.claude/skills/$skill/SKILL.md"
  dst_dir="$CLAUDE/skills/$skill"
  mkdir -p "$dst_dir"
  cp -f "$src" "$dst_dir/SKILL.md"
  echo "  skill  -> $dst_dir/SKILL.md"
done

# 5. Hook — copy into ~/.claude/hooks/ so the live config has no runtime dependency on the repo
mkdir -p "$CLAUDE/hooks"
HOOK_DST="$CLAUDE/hooks/inject-utils-catalog.py"
cp -f "$REPO/hooks/inject-utils-catalog.py" "$HOOK_DST"
chmod +x "$HOOK_DST"
echo "  hook   -> $HOOK_DST"

# 6. Register the SessionStart hook for ALL FOUR matchers (startup|resume|clear|compact) —
#    idempotent, preserves all existing keys, bakes in the concrete absolute path.
SETTINGS="$CLAUDE/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
python3 - "$SETTINGS" "$HOOK_DST" <<'PY'
import json, sys
settings_path, hook_path = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    s = json.load(f)
cmd = f"python3 {hook_path}"
hooks = s.setdefault("hooks", {})
session_start = hooks.setdefault("SessionStart", [])
already = any(
    h.get("command") == cmd
    for entry in session_start
    for h in entry.get("hooks", [])
)
if not already:
    session_start.append({
        "matcher": "startup|resume|clear|compact",
        "hooks": [{"type": "command", "command": cmd}],
    })
    with open(settings_path, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    print("  hook registered in settings.json (SessionStart, startup|resume|clear|compact)")
else:
    print("  hook already registered in settings.json (no change)")
PY

# 7. Durable pointer (discovery layer 2) — one line in the user's CLAUDE.md that survives
#    compaction; the floor that never vanishes even when the hook snapshot is stale/absent.
#    Replace-in-place on redeploy (matched by the stable anchor prefix) so wording updates
#    actually propagate; append if absent; collapse any accidental duplicates.
USER_MD="$CLAUDE/CLAUDE.md"
POINTER='Reusable CLI utils live in a global library (run `gu list` for the current set; the in-context catalog is a snapshot). Default to a util over inline code: before writing more than a trivial one-liner of shell or Python, use a util that fits, or create one with the create-util skill when the need is reusable and none exists.'
touch "$USER_MD"
python3 - "$USER_MD" "$POINTER" <<'PY'
import sys
path, pointer = sys.argv[1], sys.argv[2]
anchor = "Reusable CLI utils live in a global library"
lines = open(path).read().splitlines()
kept, seen = [], False
for ln in lines:
    if anchor in ln:
        if not seen:
            kept.append(pointer); seen = True
        # drop this and any later duplicate pointer lines
    else:
        kept.append(ln)
if not seen:
    if kept and kept[-1].strip():
        kept.append("")
    kept.append(pointer)
    action = "appended"
else:
    action = "unchanged" if pointer in lines else "refreshed"
open(path, "w").write("\n".join(kept) + "\n")
print(f"  CLAUDE.md pointer {action} -> {path}")
PY

# 8. Custom-location reminder
if [ -n "${GLOBAL_UTILS_HOME:-}" ]; then
  echo "  note: GLOBAL_UTILS_HOME is set ($GLOBAL_UTILS_HOME) — persist it in your shell rc:"
  echo "        export GLOBAL_UTILS_HOME=\"$GLOBAL_UTILS_HOME\""
fi

echo "Done. Restart Claude Code so the new settings.json hook takes effect; then"
echo "/create-util and /revise-util are available everywhere, and 'gu list' shows the catalog."
