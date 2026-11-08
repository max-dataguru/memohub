# CLAUDE.md — memohub

Personal memory for AI chats (Claude, ChatGPT, Codex) on Supabase. Overview: README.md; saving and
reading rules: docs/CONTRACT.md (the source of truth for the texts in clients/ and the plugins).

- Everything in the repository is in English: docs, client texts, code comments, commit messages.
- No coordinates in commits: `project_ref`, passwords, connection strings, NAS paths go in
  placeholders or env. Never print secrets.
- Two databases with one schema: `memohub` (shared) and `memohub-private` (`targets/private`).
  The schema changes only through a new migration in `supabase/migrations/` with
  `tests/run-local.sh` green; `scripts/db-push.sh` applies it to both, only when explicitly asked.
- When a `memohub.*` function or field changes, update CONTRACT.md, `clients/guide.md` and the
  plugins together, then run `scripts/sync-guide.sh` (only when explicitly asked, like
  migrations). The loader texts in clients/ only point to `memohub.guide()` and need no changes.
- Commit / push only when asked.
