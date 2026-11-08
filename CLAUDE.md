# CLAUDE.md — memohub

Personal memory for AI chats (Claude, ChatGPT, Codex) on Supabase. Overview: README.md; saving and
reading rules: docs/CONTRACT.md (the source of truth for the texts in clients/ and the plugins).

- Everything in the repository is in English: docs, client texts, code comments, commit messages.
- The repository is public. `.githooks/` (leak guard, `scripts/guard.sh`) must stay enabled; never
  bypass it with `--no-verify`. If it blocks, fix the content.
- No coordinates in commits: `project_ref`, passwords, connection strings, server paths go in
  placeholders or env. Never print secrets.
- Two databases with one schema: `memohub` (shared) and `memohub-private` (`targets/private`).
  The schema changes only through a new migration in `supabase/migrations/` with
  `tests/run-local.sh` green; `scripts/db-push.sh` applies it to both, only when explicitly asked.
- When a `memohub.*` function or field changes, update CONTRACT.md, `clients/guide.md` and the
  plugins together, then run `scripts/sync-guide.sh` (only when explicitly asked, like
  migrations). The loader texts in clients/ only point to `memohub.guide()` and need no changes.
- Work on a branch and open a PR; never commit to `main` directly. Add a line to CHANGELOG.md
  under "Unreleased"; bump the plugin version in the same PR when a plugin changes.
- Releases: tag `vX.Y.Z` on `main`, then `scripts/deploy.sh vX.Y.Z` (add `--migrate` only when
  explicitly asked, like `db-push.sh`). The launchd jobs run from `~/.memohub/app`, not from here.
- Commit / push only when asked.
