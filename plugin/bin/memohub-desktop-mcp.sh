#!/bin/sh
# Claude Desktop MCP entry for memohub (claude_desktop_config.json → "command").
# With MEMOHUB_CLI_LOGIN=1 (set in the server's "env") mcp-remote sends the token that
# `supabase login` keeps in the macOS Keychain, so there is no browser OAuth and no refresh-token
# race between the Desktop's Chat and Code-session copies. Otherwise: plain mcp-remote (OAuth).
# Usage: memohub-desktop-mcp.sh <project_ref>
: "${1:?project ref}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
url="https://mcp.supabase.com/mcp?project_ref=$1&features=database"
if [ "${MEMOHUB_CLI_LOGIN:-}" = "1" ]; then
  t="$(/usr/bin/security find-generic-password -s "Supabase CLI" -a supabase -w 2>/dev/null)"
  case "$t" in go-keyring-base64:*) t="$(printf %s "${t#go-keyring-base64:}" | /usr/bin/base64 -d)" ;; esac
  case "$t" in
    sbp_*) export MEMOHUB_AUTH="Bearer $t"
           exec npx -y mcp-remote "$url" --header "Authorization:\${MEMOHUB_AUTH}" ;;
  esac
fi
exec npx -y mcp-remote "$url"
