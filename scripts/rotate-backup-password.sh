#!/usr/bin/env bash
# Rotate the memohub_backup password in both databases. The new password goes only to the
# Keychain; the database receives a SCRAM-SHA-256 verifier computed here. Nothing is printed.
set -euo pipefail
cd "$(dirname "$0")/.."
. "$HOME/.memohub/backup.conf"
PSQL="$(command -v psql || echo /opt/homebrew/opt/libpq/bin/psql)"

for t in shared private; do
  dir=.; [ "$t" = private ] && dir=targets/private
  T="$(printf %s "$t" | tr '[:lower:]' '[:upper:]')"; host_var="${T}_HOST"; ref_var="${T}_REF"
  pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-40)"
  verifier="$(PW="$pw" python3 -I -c '
import base64, hashlib, hmac, os
pw = os.environ["PW"].encode(); salt = os.urandom(16); it = 4096
salted = hashlib.pbkdf2_hmac("sha256", pw, salt, it)
stored = hashlib.sha256(hmac.new(salted, b"Client Key", "sha256").digest()).digest()
server = hmac.new(salted, b"Server Key", "sha256").digest()
b = lambda x: base64.b64encode(x).decode()
print(f"SCRAM-SHA-256${it}:{b(salt)}${b(stored)}:{b(server)}")')"
  supabase --workdir "$dir" db query --linked "alter role memohub_backup password '$verifier'" >/dev/null 2>&1 \
    || { echo "$t: alter role failed, Keychain unchanged"; exit 1; }
  security add-generic-password -U -a memohub-backup -s "memohub-backup-$t" -w "$pw"
  unset pw verifier
  ok=0
  for i in 1 2 3 4 5 6; do
    if PGPASSWORD="$(security find-generic-password -a memohub-backup -s "memohub-backup-$t" -w)" \
       PGHOST="${!host_var}" PGPORT=5432 PGUSER="memohub_backup.${!ref_var}" PGDATABASE=postgres \
       PGSSLMODE=require PGCONNECT_TIMEOUT=20 \
       "$PSQL" -X -q -tA -c "select 'login ok, forgotten readable: ' || (select count(*) from memohub.forgotten)" 2>/dev/null; then
      ok=1; break
    fi
    sleep 10
  done
  [ "$ok" = 1 ] && echo "$t: rotated" || { echo "$t: rotated, but login with the new password failed"; exit 1; }
done
