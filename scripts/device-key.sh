#!/usr/bin/env bash
# Device keys for the iPhone Shortcut "Thought". A key can only add thoughts to the journal.
#   device-key.sh create <device> [private|shared]   new key (revokes the device's old one); shown once
#   device-key.sh revoke <device> [private|shared]   revoke at once (lost phone)
#   device-key.sh list   [private|shared]
# Default database: private (thoughts are raw, like the journal). Run it in your own terminal:
# the key is made here (openssl), printed only here; the database gets its SHA-256 only.
set -euo pipefail
cd "$(dirname "$0")/.."
cmd="${1:-}"; dev="${2:-}"; target="${3:-private}"
[ "$cmd" = list ] && { target="${2:-private}"; dev=""; }
case "$target" in shared) wd=.;; private) wd=targets/private;; *) echo "target: private|shared" >&2; exit 2;; esac
q() {
  supabase --workdir "$wd" db query --linked --output-format json "$1" 2>/dev/null \
    | sed -n '/^[[{]/,$p' | jq -c '(if type == "object" then .rows else . end)[0] | to_entries[0].value'
}
case "$cmd" in
  create)
    [ -n "$dev" ] || { echo "usage: $0 create <device> [private|shared]" >&2; exit 2; }
    # The key is made here; only its SHA-256 goes to the database.
    key="mh_$(openssl rand -hex 32)"
    hash="$(printf '%s' "$key" | shasum -a 256 | cut -d' ' -f1)"
    r="$(q "select memohub.device_key_create('$dev', '$hash')")"
    [ "$(jq -r .ok <<<"$r")" = true ] || { echo "$r" >&2; exit 1; }
    ref="$(cat "$wd/supabase/.temp/project-ref")"
    echo "device:  $dev ($target)"
    echo "URL:     https://$ref.supabase.co/rest/v1/rpc/capture_thought"
    pub="$(supabase projects api-keys --project-ref "$ref" -o json 2>/dev/null \
      | jq -r '[.[] | select(.type == "publishable")][0].api_key // empty')"
    echo "apikey:  ${pub:-<publishable key from Project Settings → API Keys>}   (public, safe to put in the Shortcut)"
    echo "key:     $key"
    echo "Put the key into the Shortcut (docs/SHORTCUT.md) and clear this terminal; it is not shown again." ;;
  revoke)
    [ -n "$dev" ] || { echo "usage: $0 revoke <device> [private|shared]" >&2; exit 2; }
    q "select memohub.device_key_revoke('$dev')" ;;
  list)
    q "select memohub.device_keys_list()" | jq . ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
