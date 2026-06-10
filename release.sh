#!/usr/bin/env bash
# release.sh — cut a release from CHANGELOG.md: tag, push, and create the GitHub release.
#
# Usage:
#   ./release.sh <version> [--dry-run]
#
#   <version>   e.g. 0.3.1 or v0.3.1. A matching "## [X.Y.Z] - YYYY-MM-DD" section must
#               already exist in CHANGELOG.md (move your [Unreleased] bullets there first).
#   --dry-run   print the notes and the planned actions, then stop. Makes no changes and
#               needs no clean tree — safe to run anytime to preview.
#
# What a real run does, in order: extract notes from the changelog, verify preconditions
# (gh authed, clean tree, tag/release absent), push the branch, create + push an annotated
# tag at HEAD, and create the GitHub release with those notes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# --- parse args ---
DRY_RUN=0; VERSION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*) echo "error: unknown flag '$arg'" >&2; exit 1 ;;
    *) [ -z "$VERSION" ] && VERSION="$arg" || { echo "error: unexpected extra arg '$arg'" >&2; exit 1; } ;;
  esac
done
[ -n "$VERSION" ] || { echo "error: version required, e.g. ./release.sh 0.3.1" >&2; exit 1; }
VERSION="${VERSION#v}"
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "error: '$VERSION' is not semver X.Y.Z" >&2; exit 1; }
TAG="v$VERSION"

# --- extract this version's notes + date from CHANGELOG (read-only; works in dry-run) ---
NOTES_FILE="$(mktemp)"; trap 'rm -f "$NOTES_FILE"' EXIT
DATE="$(VERSION="$VERSION" NOTES_FILE="$NOTES_FILE" python3 - <<'PY'
import os, re, sys
ver, out = os.environ["VERSION"], os.environ["NOTES_FILE"]
cur = date = None; buf = []; found = None
for line in open("CHANGELOG.md").read().splitlines():
    m = re.match(r'^## \[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})\s*$', line)
    if m:
        if cur == ver: found = (date, "\n".join(buf).strip() + "\n")
        cur, date, buf = m.group(1), m.group(2), []; continue
    if re.match(r'^## \[Unreleased\]', line) or re.match(r'^\[[^\]]+\]: http', line):
        if cur == ver: found = (date, "\n".join(buf).strip() + "\n")
        cur = None; continue
    if cur is not None: buf.append(line)
if cur == ver and found is None: found = (date, "\n".join(buf).strip() + "\n")
if not found:
    sys.stderr.write(f"error: no '## [{ver}] - YYYY-MM-DD' section in CHANGELOG.md\n"); sys.exit(3)
date, body = found
if not body.strip():
    sys.stderr.write(f"error: changelog section for {ver} is empty\n"); sys.exit(4)
open(out, "w").write(body); print(date)
PY
)"
grep -qE "^\[$VERSION\]: http" CHANGELOG.md || \
  echo "warning: no '[$VERSION]: …' link reference in CHANGELOG.md (the version header won't be a link)." >&2

# --- is this the highest version (→ mark Latest)? otherwise don't steal the badge ---
HIGHEST="$(printf '%s\n' $(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//') "$VERSION" | sort -V | tail -1)"
if [ "$HIGHEST" = "$VERSION" ]; then LATEST=(--latest); else LATEST=(--latest=false); fi

TITLE="$TAG ($DATE)"
echo "── $TITLE ${LATEST[*]} ──"
sed 's/^/  /' "$NOTES_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would tag $TAG at $(git rev-parse --short HEAD), push, and create the release above."
  exit 0
fi

# --- real-run preconditions ---
command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated (gh auth login)" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "error: working tree not clean — commit the CHANGELOG edit first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "error: tag $TAG already exists locally." >&2; exit 1; } || true
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && { echo "error: tag $TAG already exists on origin." >&2; exit 1; } || true
gh release view "$TAG" >/dev/null 2>&1 && { echo "error: release $TAG already exists." >&2; exit 1; } || true

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
DEFAULT="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo master)"
[ "$BRANCH" = "$DEFAULT" ] || echo "warning: releasing from '$BRANCH', not default '$DEFAULT'." >&2

# --- cut it ---
git push origin "$BRANCH"
git tag -a "$TAG" -m "Release $TAG ($DATE)"
git push origin "$TAG"
gh release create "$TAG" --verify-tag "${LATEST[@]}" --title "$TITLE" --notes-file "$NOTES_FILE"
echo "Released $TAG. Next: add a fresh '## [Unreleased]' section to CHANGELOG.md for ongoing changes."
