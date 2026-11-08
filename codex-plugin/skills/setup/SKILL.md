---
name: setup
description: Connect Memohub in Codex and check authorization.
---

# Setting up Memohub

1. Make sure the `memohub` MCP server is enabled in the plugin settings and points to the shared
   database. The home Mac may also have a separate `memohub-private` server for sensitive topics.
2. If Codex offers authorization, open the link and finish the OAuth sign-in to Supabase.
3. Check each configured server by calling `select memohub.guide()` with the `execute_sql` tool.
   Follow the instructions it returns, especially the limits: call only `memohub.*` functions,
   do not change or delete data.
4. Suggest the user try `$memohub-memory` to search or `$tomemo` to save.

If the MCP tools are not visible after sign-in, ask the user to restart the Codex session and
check that the Memohub plugin is installed and enabled.
