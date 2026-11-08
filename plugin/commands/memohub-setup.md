---
description: Set up memohub on this computer (variables, CLI, private database)
argument-hint: "[work-mac | home-mac]"
---

Set up memohub on this computer. Argument: $ARGUMENTS

1. **Device.** `work-mac` or `home-mac`, from the argument or `$MEMOHUB_DEVICE`; if neither, ask.
   A work laptop is `work-mac`.
2. **Supabase CLI** (needed for `/memofile` and for finding projects): `supabase --version`.
   Missing: offer `brew install supabase/tap/supabase` and install after a "yes".
   Then `supabase projects list -o json`. On an auth error, ask the user to run
   `! supabase login` (needs a browser) and retry.
3. **Projects.** From the list take the ref of the project named `memohub`. `memohub-private` is
   **only** for `home-mac`; on `work-mac` do not connect the private database and do not write its
   ref.
4. **Variables** in `~/.claude/settings.json` → `env` (keep the other keys; back up to
   `settings.json.bak-<date>` before writing): `MEMOHUB_REF`, `MEMOHUB_DEVICE`, and for `home-mac`
   also `MEMOHUB_PRIVATE_REF`. Do not repeat ref values in your reply.
5. **Sign-in without a browser (optional, recommended only for `home-mac`).** Ask the user.
   If yes: copy `${CLAUDE_PLUGIN_ROOT}/bin/memohub-auth-header.sh` to `~/.claude/bin/`
   (`chmod +x`) and add `MEMOHUB_CLI_LOGIN=1` to env. The connectors then use the token that
   `supabase login` keeps in Keychain, and `/mcp` → Authenticate is no longer needed. The token
   grants access to the whole Supabase account, so do not turn this on by default on a work laptop.
6. **Private database (`home-mac` only):** if there is no `memohub-private` server yet,
   `claude mcp add-json --scope user memohub-private '{"type":"http","url":"https://mcp.supabase.com/mcp?project_ref=<private ref>&features=database","headersHelper":"~/.claude/bin/memohub-auth-header.sh"}'`
   (absolute path to the helper; without step 5, drop `headersHelper`).
7. **Claude Desktop (Chat), optional.** Copy `${CLAUDE_PLUGIN_ROOT}/bin/memohub-desktop-mcp.sh`
   to `~/.claude/bin/` (`chmod +x`) and in
   `~/Library/Application Support/Claude/claude_desktop_config.json` → `mcpServers` add
   `"memohub": {"command": "<absolute path to the script>", "args": ["<memohub ref>"]}` (back up
   the config first); with step 5 also add `"env": {"MEMOHUB_CLI_LOGIN": "1"}`.
   The user restarts Desktop (Cmd+Q) and checks that Desktop did not restore the old config.
8. **PDF text** for `/memofile`: `pdftotext -v`; missing, offer `brew install poppler` (optional:
   without it the model reads the PDF itself).
9. **Summary for the user:**
   - restart the Claude Code session (variables and MCP are read at start);
   - without step 5: `/mcp` → `plugin:memohub:memohub` → Authenticate → the organization with the
     memohub projects (on `home-mac`, the same for `memohub-private`); with step 5, nothing;
   - check in a new session: "what is in memohub about the memohub project?".
