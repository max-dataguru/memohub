# Changelog

Each release is a `vX.Y.Z` tag on `main`. Patch: fixes. Minor: new features or migrations.
Major: changes that need manual steps on existing installs. Migrations are listed because they
change both databases.

## Unreleased

- CI runs once per change: on pull requests, and on pushes to `main` and release tags.
## v0.3.2 - 2026-11-12

- Distiller and health report: timestamps with fewer than 6 fraction digits no longer fail on the
  system Python 3.9 that launchd runs; since v0.3.0 every distilled chat failed after the model
  answered. CI now runs the Python tests on 3.9, with a new `tests/distill_test.py`.
- `deploy.sh` accepts a capture scan from the last 11 minutes when the restarted job found the
  previous run still holding its lock, as long as no new errors were logged.

## v0.3.1 - 2026-11-09

- `distill-eval.py` uses the nightly distiller's prompt, input and validation, so the eval
  measures what runs at night. Ollama runs send at most 60 000 characters per chat (32k-token
  context); `distill.py` reads `~/.memohub/ollama.url` like the eval.

## v0.3.0 - 2026-11-09

Migration `20261112120000_distill_similar.sql`: deploy with `--migrate`.

- Distiller: chats in a code repository yield notes only about what the repository does not
  record (plans, open problems, unbuilt or deferred work, rejected options, agreements). A
  candidate whose topic already has a newer note, in either database, is not proposed.
  Migration `20261112120000_distill_similar.sql`.

## v0.2.1 - 2026-11-09

- Distiller: a note without a project gets the project whose name or alias matches the chat's
  folder; the private run also reads the shared catalog, where work projects live.

## v0.2.0 - 2026-11-09

Migration `20261111120000_distill.sql`: deploy with `--migrate`.

- Distiller: `scripts/distill.py` and `install-distill.sh` propose candidates from finished
  chats nightly, with a local Ollama model or headless Claude Code. Off until a source is
  allowed. Migration `20261111120000_distill.sql` (cursors, runs, pause, `health().distill`).
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
