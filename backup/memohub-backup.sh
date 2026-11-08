#!/usr/bin/env bash
# Nightly encrypted backup of memohub data from Supabase (cron job on a backup host).
# The daily connection also keeps a free-tier project from pausing.
# Run once per project (memohub, memohub-private) with its own env file and directory.
#
# Data only, as one JSON document: pg_dump hangs behind the Supabase pooler, plain psql does
# not. The schema lives in supabase/migrations; restore = migrations + backup/memohub-restore.sh.
#
#   MEMOHUB_BACKUP_ENV        env file with PGHOST, PGPORT, PGUSER, PGDATABASE,
#                             PGPASSWORD, PGSSLMODE (KEY=value, no quotes), chmod 600
#   MEMOHUB_BACKUP_DIR        target directory
#   MEMOHUB_BACKUP_RECIPIENT  age public key (age1...); the private key never lives on the backup host
#   MEMOHUB_BACKUP_KEEP_DAYS  retention, default 30
#   MEMOHUB_PG_IMAGE          image with psql, default postgres:17-alpine
set -euo pipefail

: "${MEMOHUB_BACKUP_ENV:?path to the connection env file}"
: "${MEMOHUB_BACKUP_DIR:?target directory}"
: "${MEMOHUB_BACKUP_RECIPIENT:?age public key - backups are never written unencrypted}"
KEEP_DAYS="${MEMOHUB_BACKUP_KEEP_DAYS:-30}"
IMAGE="${MEMOHUB_PG_IMAGE:-postgres:17-alpine}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$MEMOHUB_BACKUP_DIR/memohub-$stamp.json.gz.age"
tmp="$out.partial"
trap 'rm -f "$tmp"' EXIT

EXPORT_SQL="$(grep -v '^--' "$(dirname "$0")/export.sql")"

# Export, sanity-check and encrypt inside the container: plaintext never touches the backup host's disk.
# `timeout` (Linux; absent on macOS) guards against a hung connection; --init lets signals reach psql.
TO=""; command -v timeout >/dev/null && TO="timeout 300"
$TO docker run --rm --init --network "${MEMOHUB_BACKUP_NETWORK:-bridge}" \
  --env-file "$MEMOHUB_BACKUP_ENV" -e RECIPIENT="$MEMOHUB_BACKUP_RECIPIENT" -e EXPORT_SQL="$EXPORT_SQL" \
  "$IMAGE" sh -euc '
    apk add -q --no-cache age >/dev/null
    psql -v ON_ERROR_STOP=1 -X -q -t -A -c "$EXPORT_SQL" > /tmp/export.json
    grep -q "\"format\" *: *\"memohub-json-1\"" /tmp/export.json || { echo "export looks empty" >&2; exit 1; }
    gzip -c /tmp/export.json | age -r "$RECIPIENT"
  ' > "$tmp"

mv "$tmp" "$out"
find "$MEMOHUB_BACKUP_DIR" -name 'memohub-*.gz.age' -mtime +"$KEEP_DAYS" -delete
echo "ok $out"
