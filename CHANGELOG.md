# Changelog

Each release is a `vX.Y.Z` tag on `main`. Patch: fixes. Minor: new features or migrations.
Major: changes that need manual steps on existing installs. Migrations are listed because they
change both databases.

## Unreleased

- The pre-push guard skips commits that are already on the remote.
- `scripts/distill-eval.py`: offline evaluation of note distillation with a local Ollama model or
  headless Claude Code; nothing is written to the databases.
- Logo (`docs/assets/logo.svg`) in the README and a social preview image.
- Docs, client texts, comments and eval data describe devices and the backup host in generic
  terms (plugin 1.12.1, Codex plugin 1.0.7).
- `docs/ARCHITECTURE.md`: parts, Supabase dependencies and the feature convention.
- ROADMAP: local embeddings, releases and the architecture note moved to Done.
- `deploy.sh` reports the previous version as `none` on the first deploy.

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
