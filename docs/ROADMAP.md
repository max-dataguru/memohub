# Roadmap

## Done

- Notes with versions, catalog (spaces and projects), tags, entities and a relation graph.
- Search: Russian full-text with substring fallback; multi-query search for clients that cannot
  compute embeddings; optional hybrid search with local embeddings.
- Privacy guards in `save()`: card numbers, IBANs, passport numbers and credentials are refused;
  the `medicine` space stays in the private database.
- Files in Supabase Storage with quota and duplicate checks; extracted text is searchable.
- Forgetting a note or a chat, with tombstones so that a restore does not bring it back.
- Daily encrypted backup from a Mac and a tested restore.
- Chat journal: raw messages from Claude Code, Codex and meeting transcripts, masked before
  sending; `#nomemo` and `#memo` tags.
- "Thought" Shortcut on iPhone with a per-device key that can only append to the journal.
- Weekly health report.
- Note candidates: automation can propose notes; only a person turns them into notes.
- Tests in CI: migrations and smoke test, backup round trip, search eval, scanner, secret scan.
- Local embeddings on the Mac with Ollama, no separate server.
- Releases: tags, a changelog, a deploy script and a leak guard on every commit and push.
- [Architecture note](ARCHITECTURE.md): parts, Supabase dependencies, the feature convention.

## Next

1. **Distillation.** Rules select journal chats with decisions and plans; a model proposes
   candidates (local Ollama by default, or any OpenAI-compatible API with your own key); you
   approve them. Measured on 20 labelled chats before it is switched on, then enabled per source.
2. **Self-hosted private database.** Run the private database on plain Postgres in Docker; the
   shared one stays on Supabase for phone and web clients.

## Principles

- Works without paid subscriptions or API keys: local models by default. Hosted model APIs with
  your own key are an option, never a requirement.
- New database logic uses plain Postgres; Supabase-only features are kept to where they are needed.
- Automation never writes notes on its own: it proposes, a person approves.
- Exports, backups and restores do not depend on the hosting.
- Generic mechanisms (an installer, a daemon, a module registry) wait until there is a second real
  user or a second hosting option.
