# Installing memohub

memohub is personal memory for AI chats. Summaries and decisions from Claude (web, iPhone,
Desktop, Claude Code), ChatGPT and Codex are stored in your own Postgres database, and every
connected client can find them, a phone included. This guide sets it up from scratch: what works
today and what is planned.

It is a personal project and not yet a packaged product. The setup works, but it assumes one
person with a Mac and is done by hand, step by step. The end of this page lists what will get
simpler.

## Requirements

- A Supabase account on the free tier.
- A Mac with Homebrew. Background jobs run under launchd; there is no Linux or Windows support.
- Optional: Docker for the tests, `age` and `libpq` (`psql`) for backups,
  [Ollama](https://ollama.com) for semantic search, a NAS or another disk for backup copies.
  All of them install with `brew install`.

The basic setup needs no paid subscriptions or API keys: Claude and ChatGPT reach the database
through your normal sign-in to those apps, and models can run locally. If you prefer a hosted model
API, you can use your own key instead (see below).

## Components

Only the database is required. Everything else can be turned on separately.

| Component | Runs on | What it gives you | Status |
|---|---|---|---|
| Database (`memohub` schema) | Supabase | notes, search, catalog, forgetting | ready |
| Clients: Claude, ChatGPT, Claude Code, Codex | your devices | save a summary (`tomemo`), find the past | ready |
| Chat journal (`capture.py`) | every Mac you work on | raw Claude Code, Codex and meeting messages | ready |
| Thoughts from a phone (Shortcut) | iPhone | voice note into the journal | ready |
| Backup (`mac-backup.sh`) | Mac | daily encrypted export | ready |
| Health report (`health.py`) | Mac | weekly: is everything still being collected | ready |
| Semantic search (embeddings) | Ollama | search by meaning on top of search by words | ready |
| Meeting recording | Mac, separate `meeting` plugin | transcript and summary; the transcript goes into the journal | ready |
| Note candidates | database | automation proposals waiting for your approval | ready |
| Distillation | Mac, Ollama | automation proposes candidates from the journal | in progress |

## Where it runs

**Today:** two databases with one schema on Supabase free tier. The shared one holds work,
learning and travel; the private one holds medical, money, documents and family. Connect the
private database only to your home devices. A work laptop and a company Claude account see only
the shared one. `db-push.sh` and `sync-guide.sh` do not support a single-database setup yet.

Models (embeddings now, distillation later) run in Ollama by default, so note text does not leave
your network. Any OpenAI-compatible endpoint works instead, a hosted API with your own key
included; then the text goes to that provider.

**Planned:** the private database on your own Postgres at home. The shared database stays on
Supabase: Claude on a phone or the web and ChatGPT connect to memory from their own servers and
need an internet-facing address.

## Setup

### 1. Database

```bash
brew install supabase/tap/supabase
git clone https://github.com/max-dataguru/memohub.git memohub && cd memohub
supabase login
```

In Supabase, create two projects, `memohub` and `memohub-private`, in one organization, in the
region closest to you. You set a database password when creating a project; `supabase link` asks
for it. Then:

```bash
supabase link --project-ref <shared ref>
supabase --workdir targets/private link --project-ref <private ref>
security add-generic-password -a memohub-private -s supabase-memohub-private-db -w   # prompts for the private database password
./scripts/db-push.sh --dry-run      # shows what will be applied
./scripts/db-push.sh
```

The `ref` is in each project's Project Settings. Do not commit it: the link is stored in
`supabase/.temp/`, which git ignores. In the private database, run this once in the SQL Editor:

```sql
insert into memohub.config values ('tier', 'private');
```

Instructions for the models live in the database. Load them:

```bash
./scripts/sync-guide.sh
./scripts/sync-guide.sh --check     # both databases answer and match the file
```

### 2. Clients

- **Claude (web, iPhone, iPad).** Settings → Connectors → Add custom connector, URL
  `https://mcp.supabase.com/mcp?project_ref=<ref>&features=database`. Set `execute_sql` to
  "Always allow" and `apply_migration` to "Ask". Paste the block from
  [clients/claude-preferences.md](../clients/claude-preferences.md) into your personal preferences.
- **ChatGPT.** The Supabase app (the organization with the memohub projects) plus the
  instructions from [clients/chatgpt-instructions.md](../clients/chatgpt-instructions.md).
  ChatGPT sees every project in the organization, so turn off training on chats and ChatGPT memory.
- **Claude Code.**
  ```bash
  claude plugin marketplace add max-dataguru/memohub
  claude plugin install memohub@memohub --scope user
  ```
  Then run `/memohub-setup home-mac` in Claude Code, restart the session and press Authenticate
  in `/mcp`.
- **Codex.** `./scripts/install-codex-plugin.sh <shared ref> home-mac [<private ref>]`, then
  restart Codex, install Memohub from Plugins → personal marketplace and sign in. Details:
  [clients/codex.md](../clients/codex.md).

Check: ask each client "show the memohub catalog". A list of spaces means the connection works.
If the client asks you to sign in, sign in to Supabase and pick the organization with the memohub
projects. Then say "tomemo" at the end of a conversation and ask another client "what did we
decide about …".

### A second device with the shared database only

For a work laptop: install the Claude Code plugin the same way and run `/memohub-setup work-mac`.
It installs the Supabase CLI if needed, asks you to run `supabase login` once, finds the shared
project and writes the variables. It never connects the private database. Restart the session,
then `/mcp` → `plugin:memohub:memohub` → Authenticate. Sign-in without a browser
(`MEMOHUB_CLI_LOGIN=1`) is off by default there: that token grants access to your whole Supabase
account.

### 3. Optional features

**Chat journal.** Every 10 minutes the scanner collects Claude Code, Codex and meeting messages,
masks secrets and sends them to the database. A chat containing `#nomemo` is skipped.

```bash
mkdir -p ~/.memohub
cat > ~/.memohub/capture.conf <<'EOF'
DEVICE=home-mac
TARGET=private
MODE=all
SOURCES=claude-code,codex,meeting
EOF
./scripts/install-capture.sh
```

On a work laptop use `TARGET=shared`, `MODE=projects` and a `PROJECTS` list: only those projects
and chats tagged `#memo` reach the shared database. Log: `~/.memohub/capture.log`.

**Backup.** Daily; a run missed while the Mac slept starts after wake. Copies are encrypted with a
key only you hold.

1. `brew install age libpq`, then `mkdir -p ~/.memohub && age-keygen -o ~/.memohub/backup.key`.
   Put a copy of the key in your password manager: without it the backups cannot be decrypted.
2. In each database, run [supabase/manual/backup_role.sql](../supabase/manual/backup_role.sql) in
   the SQL Editor with your own password instead of the placeholder. Store the passwords in
   Keychain:
   ```bash
   security add-generic-password -a memohub-backup -s memohub-backup-shared -w
   security add-generic-password -a memohub-backup -s memohub-backup-private -w
   ```
3. Create `~/.memohub/backup.conf`. The pooler host is in Supabase: Connect → Session pooler, host.
   ```
   TARGETS="shared private"
   SHARED_HOST=<shared pooler host>
   SHARED_REF=<shared ref>
   PRIVATE_HOST=<private pooler host>
   PRIVATE_REF=<private ref>
   ```
   Optional NAS copy: `NAS_SSH` and `NAS_DIR`.
4. `./scripts/install-mac-backup.sh`. Check the next day: `~/.memohub/backup.log` has
   `ok shared …` and `ok private …` lines and `~/.memohub/backups/` has `.age` files.

Copies are kept for 30 days in `~/.memohub/backups/` and on the NAS, if configured. To restore:
apply migrations to an empty database, then
`backup/memohub-restore.sh <file.age> <connection string>`.

**Semantic search.** Needs Ollama with `embeddinggemma-2:270m`. The example below runs Ollama on
the same Mac. If it runs on another machine, pull the model there and put that address in
`ollama.url`.

```bash
brew install ollama && brew services start ollama
ollama pull embeddinggemma-2:270m
echo http://localhost:11434 > ~/.memohub/ollama.url
```

Vectors for new notes are computed before the daily backup. Combined search by meaning and by
words: `memohub-hybrid-search.sh '<question>'` from the Codex plugin. Without Ollama, search uses
words only. Vectors from different Ollama builds of the same model differ slightly, so keep one
Ollama for all vectors, or recompute them all when you switch.

**Thoughts from a phone.** The "Thought" Shortcut adds text or dictation to the journal.
Its device key can only add thoughts. Setup: [SHORTCUT.md](SHORTCUT.md).

**Health report.** `./scripts/install-health.sh` runs on Mondays and shows a notification only
when something stopped being collected.

**Meeting recording.** The separate [`meeting`](https://github.com/max-dataguru/meeting-notes)
plugin for Claude Code records meeting audio and video and writes a transcript and summary; it is
also listed in this repository's marketplace (`/plugin install meeting@memohub`), and its README
covers setup. Transcripts land in
`~/Documents/Meetings`, and the journal picks them up (the `meeting` source in `capture.conf`).
On first run macOS asks for access to Documents.

**Distillation (in progress).** A script on the Mac will take journal messages, pick by rules the
ones that contain decisions and plans, and ask a model to propose notes: by default a local
`qwen3` in Ollama, or any OpenAI-compatible API with your own key. Proposals become candidates and turn into notes only after you approve them in any client ("show
candidates"). Only sources you allow in `distill.allow` are read. Quality is measured on 20
labelled chats before it is switched on.

## Security

- Project addresses, passwords and keys are never stored in the repository; gitleaks in CI checks
  this.
- `save()` refuses card numbers, IBANs, passport numbers and passwords. The journal masks them
  before sending.
- Forgetting deletes a note with every version, file and vector, and an older backup cannot bring
  it back.
- The private database is never connected to work devices.

## Current rough edges

- Setup is long: thirty minutes to an hour with everything.
- Device names `home-mac` and `work-mac`, Russian full-text search and launchd are tuned for one
  user.
- Both databases are required: `db-push.sh` and `sync-guide.sh` work only with two.
- Clients reach the database through Supabase MCP (`execute_sql`), so phone and web clients need
  Supabase.

## What is planned

See [ROADMAP.md](ROADMAP.md).
