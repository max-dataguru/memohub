#!/bin/sh
# headersHelper for the Supabase MCP servers: emits an Authorization header with the access
# token that `supabase login` keeps in the macOS Keychain, so Claude Code skips the browser
# OAuth flow. Opt-in per machine with MEMOHUB_CLI_LOGIN=1; otherwise (or with no token) it
# emits {} and Claude Code falls back to OAuth.
[ "${MEMOHUB_CLI_LOGIN:-}" = "1" ] || { echo '{}'; exit 0; }
t="$(security find-generic-password -s "Supabase CLI" -a supabase -w 2>/dev/null)"
case "$t" in
  go-keyring-base64:*) t="$(printf %s "${t#go-keyring-base64:}" | base64 -d 2>/dev/null)" ;;
esac
case "$t" in
  sbp_*) printf '{"Authorization":"Bearer %s"}\n' "$t" ;;
  *) echo '{}' ;;
esac
