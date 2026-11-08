#!/usr/bin/env bash
# Push pending migrations to both databases: shared (repo root link) and private
# (targets/private link). The private DB password is read from the macOS Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"   # pass --dry-run to only list pending migrations

echo "== memohub (shared)"
supabase db push ${mode:---yes}

echo "== memohub-private"
PGPASS="$(security find-generic-password -a memohub-private -s supabase-memohub-private-db -w)"
supabase --workdir targets/private db push ${mode:---yes} -p "$PGPASS"
