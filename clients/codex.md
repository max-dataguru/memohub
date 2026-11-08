# Codex

Install the ready-made Memohub plugin for Codex from the repository root:

```bash
./scripts/install-codex-plugin.sh <project_ref> [home-mac|work-mac] [private_project_ref]
```

`project_ref` is the Reference ID of the shared `memohub` database from Supabase → Project
Settings. The second argument is `home-mac` or `work-mac`; the script asks if you omit it. The
third argument is allowed only on the home Mac: it adds a separate `memohub-private` MCP server for
finances, health, documents and family. The script makes a personal copy of the plugin in
`~/.agents/plugins/memohub` with an MCP URL limited to that database and adds it to
`~/.agents/plugins/marketplace.json`, keeping the other entries. The Codex CLI is not needed.

Then restart Codex, open Plugins Directory → personal marketplace, install Memohub and finish the
OAuth sign-in. Check that the `memohub` MCP tools are available in a session; the
`$memohub-memory` skill searches memory and `$tomemo` saves.

By default Codex connects only to the shared `memohub` database. Add the private one only on the
home Mac and only if you deliberately want Codex to reach sensitive notes.
