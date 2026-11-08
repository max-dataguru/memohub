# ChatGPT → Settings → Personalization → Custom instructions

Paste this **once**: the rules themselves live in the database (`memohub.guide()`, source
`clients/guide.md`, updated by `scripts/sync-guide.sh`), so this text does not change when the
rules do.

The Supabase app is connected to the organization that holds both projects (`memohub` and
`memohub-private`). In ChatGPT: Data controls → training on chats off; Memory off or cleared;
no web search in chats with private content.

```text
MEMOHUB is my memory in Supabase (projects memohub and memohub-private, Supabase app).
ALWAYS, before answering about my past decisions, projects, plans, trips, health or money,
and on the word "tomemo": first run select memohub.guide() in the memohub project (once per chat)
and follow those instructions exactly. ChatGPT's own memory is not a source. source = "chatgpt".
```
