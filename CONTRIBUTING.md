# Contributing

This repository is the single source of truth for the `gu` dispatcher, the two skills, and the
SessionStart hook. Edit them here, then run `./deploy.sh` to copy them into the live config —
never hand-edit the deployed copies. See [SYSTEM_DESIGN.md](SYSTEM_DESIGN.md) for the full design
and the rationale behind the settled decisions.

## Releasing

Cutting a release is one command once the changelog is updated:

1. Move your `## [Unreleased]` bullets into a new `## [X.Y.Z] - YYYY-MM-DD` section in
   [CHANGELOG.md](CHANGELOG.md), add its `[X.Y.Z]: …/compare/…` link reference, and commit that.
2. `./release.sh X.Y.Z` — extracts that section's notes, tags `vX.Y.Z` at `HEAD`, pushes,
   and creates the matching GitHub release (marked Latest only if it's the highest version).

Run `./release.sh X.Y.Z --dry-run` first to preview without changing anything.
