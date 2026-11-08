#!/usr/bin/env bash
# Daily encrypted memohub backup from a Mac (launchd). Used where the NAS cannot pull from
# Supabase itself. Each run also wakes a paused-prone free-tier project.
#
# Config: ~/.memohub/backup.conf (not in the repo):
#   TARGETS="shared private"            which databases
#   <T>_HOST=<pooler host>  <T>_REF=<project ref>   per target, T upper-cased
#   NAS_SSH=<ssh host>  NAS_DIR=<dir>   optional: copy new files to the NAS when reachable;
#                                       copies there older than KEEP_DAYS are deleted too
# Before the backup, embeddings are filled in for new notes (codex-plugin indexer, local Ollama
# from MEMOHUB_OLLAMA_URL or ~/.memohub/ollama.url); skipped if Ollama is unreachable, never fatal.
# Then Storage objects no file row refers to are deleted (scripts/storage-gc.sh), also never fatal.
# Secrets: Keychain items "memohub-backup-<target>" (backup role password).
# Key: ~/.memohub/backup.key (age identity); only its public half is used here.
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${MEMOHUB_BACKUP_CONF:-$HOME/.memohub/backup.conf}"
# shellcheck source=/dev/null
. "$CONF"
OUT="${MEMOHUB_BACKUP_OUT:-$HOME/.memohub/backups}"
KEEP_DAYS="${MEMOHUB_BACKUP_KEEP_DAYS:-30}"
PSQL="$(command -v psql || echo /opt/homebrew/opt/libpq/bin/psql)"
RECIPIENT="$(age-keygen -y "$HOME/.memohub/backup.key")"
SQL="$(grep -v '^--' backup/export.sql)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
status=0

ollama_url="${MEMOHUB_OLLAMA_URL:-$(cat "$HOME/.memohub/ollama.url" 2>/dev/null || true)}"
if [ -n "$ollama_url" ] && curl -s -m 10 -o /dev/null "$ollama_url/api/tags"; then
  for t in ${TARGETS:-shared private}; do
    dir=.; [ "$t" = private ] && dir=targets/private
    ( cd "$dir" && MEMOHUB_OLLAMA_URL="$ollama_url" "$OLDPWD/codex-plugin/bin/memohub-index-embeddings.sh" --limit 50 2>&1 ) \
      | grep -vE "new version of Supabase CLI|recommend updating" | tail -1 | sed "s/^/emb  $t /" \
      || echo "emb  $t failed (backup continues)"
  done
else
  echo "emb  skipped (Ollama not reachable)"
fi

# Remove Storage objects of forgotten notes and stale unattached uploads; never fatal.
scripts/storage-gc.sh ${TARGETS:-shared private} 2>&1 || echo "gc   failed (backup continues)"

for t in ${TARGETS:-shared private}; do
  T="$(printf %s "$t" | tr '[:lower:]' '[:upper:]')"
  host_var="${T}_HOST"; ref_var="${T}_REF"
  mkdir -p "$OUT/$t"
  out="$OUT/$t/memohub-$stamp.json.gz.age"
  if PGPASSWORD="$(security find-generic-password -a memohub-backup -s "memohub-backup-$t" -w)" \
     PGHOST="${!host_var}" PGPORT=5432 PGUSER="memohub_backup.${!ref_var}" PGDATABASE=postgres \
     PGSSLMODE=require PGCONNECT_TIMEOUT=20 \
     "$PSQL" -v ON_ERROR_STOP=1 -X -q -t -A -c "$SQL" > "$out.json" \
     && grep -q '"format" *: *"memohub-json-1"' "$out.json"; then
    gzip -c "$out.json" | age -r "$RECIPIENT" > "$out"
    echo "ok   $t $(basename "$out") $(wc -c < "$out" | tr -d ' ') bytes"
  else
    echo "FAIL $t" >&2; rm -f "$out"; status=1
  fi
  rm -f "$out.json"
  find "$OUT/$t" -name 'memohub-*.gz.age' -mtime +"$KEEP_DAYS" -delete
done

# Copy to the NAS only over a direct connection (e.g. home LAN); skip silently otherwise.
if [ -n "${NAS_SSH:-}" ] && ssh -o BatchMode=yes -o ConnectTimeout=5 "$NAS_SSH" true 2>/dev/null; then
  for t in ${TARGETS:-shared private}; do
    have="$(ssh -o BatchMode=yes "$NAS_SSH" "sudo ls $NAS_DIR/$t" 2>/dev/null || true)"
    for f in "$OUT/$t"/memohub-*.gz.age; do
      [ -e "$f" ] || continue
      b="$(basename "$f")"
      grep -qx "$b" <<<"$have" && continue
      scp -q "$f" "$NAS_SSH:/tmp/$b" \
        && ssh -o BatchMode=yes "$NAS_SSH" "sudo install -m 600 -o root -g root /tmp/$b $NAS_DIR/$t/$b && rm -f /tmp/$b" \
        && echo "nas  $t $b"
    done
    # Same retention as here: after KEEP_DAYS a forgotten note is gone from the NAS copies too.
    gone="$(ssh -o BatchMode=yes "$NAS_SSH" \
      "sudo find $NAS_DIR/$t -maxdepth 1 -name 'memohub-*.json.gz.age' -mtime +$KEEP_DAYS -print -delete | wc -l" 2>/dev/null || echo '?')"
    echo "nas  $t expired $(echo $gone)"
  done
else
  echo "nas  skipped (not reachable)"
fi
exit $status
