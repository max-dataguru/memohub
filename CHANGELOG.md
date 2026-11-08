# Changelog

Each release is a `vX.Y.Z` tag on `main`. Patch: fixes. Minor: new features or migrations.
Major: changes that need manual steps on existing installs. Migrations are listed because they
change both databases.

## Unreleased

## v0.1.0 - 2026-11-08

First public release.

- Notes with versions, catalog, tags, entities and a relation graph; full-text search with an
  optional hybrid mode on local embeddings.
- Privacy guards in `save()`, forgetting with tombstones, files in Supabase Storage.
- Chat journal from Claude Code, Codex and meeting transcripts; the "Thought" Shortcut.
- Daily encrypted backup with a tested restore; weekly health report.
- Plugins: Claude Code `memohub` 1.12.0, Codex `memohub` 1.0.6. Guide version 11.
- The `meeting` plugin is listed in the marketplace.
- Release process: tags, this changelog and `scripts/deploy.sh`; the launchd jobs run from a
  separate checkout at the deployed tag (`~/.memohub/app`).
- Leak guard: pre-commit and pre-push hooks run gitleaks, a local deny list and a commit email
  check (`scripts/guard.sh`, `.githooks/`).
