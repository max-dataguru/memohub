#!/usr/bin/env bash
# Backup -> decrypt -> restore round trip on throwaway Postgres containers.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${MEMOHUB_TEST_PG_IMAGE:-pgvector/pgvector:pg17}"
W="$(mktemp -d)"; NET="mh-rt-$$"; A="mh-rt-a-$$"; B="mh-rt-b-$$"
cleanup() { docker rm -f "$A" "$B" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
docker network create "$NET" >/dev/null
for c in "$A" "$B"; do docker run -d --rm --name "$c" --network "$NET" -e POSTGRES_PASSWORD=x "$IMAGE" >/dev/null; done
for c in "$A" "$B"; do until docker exec "$c" pg_isready -U postgres -q; do sleep 1; done; done; sleep 1
for c in "$A" "$B"; do
  docker exec -i "$c" psql -U postgres -q -v ON_ERROR_STOP=1 < tests/storage_stub.sql
  docker exec -i "$c" psql -U postgres -q -v ON_ERROR_STOP=1 < tests/auth_stub.sql
  for f in supabase/migrations/*.sql; do docker exec -i "$c" psql -U postgres -q -v ON_ERROR_STOP=1 < "$f" 2>&1 | grep -v NOTICE || true; done
done
# Data in A: the smoke test leaves notes, versions, files, config and a guide behind.
docker exec -i "$A" psql -U postgres -q -v ON_ERROR_STOP=1 -v mask_cases="$(sed 's/{{HEX40}}/0123456789abcdef0123456789abcdef01234567/g' tests/mask_cases.json)" < tests/smoke.sql >/dev/null 2>&1
docker exec -i "$A" psql -U postgres -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
select memohub.put_embedding((select id from memohub.notes order by created_at limit 1), 'test-model', '[0.1,0.2,0.3]');
SQL
sed "s/CHANGE-ME-IN-SQL-EDITOR/bk/" supabase/manual/backup_role.sql | docker exec -i "$A" psql -U postgres -q -v ON_ERROR_STOP=1
printf 'PGHOST=%s\nPGPORT=5432\nPGUSER=memohub_backup\nPGDATABASE=postgres\nPGPASSWORD=bk\nPGSSLMODE=disable\n' "$A" > "$W/env"
age-keygen -o "$W/key" 2>/dev/null
MEMOHUB_BACKUP_ENV="$W/env" MEMOHUB_BACKUP_DIR="$W" MEMOHUB_BACKUP_NETWORK="$NET" \
  MEMOHUB_BACKUP_RECIPIENT="$(age-keygen -y "$W/key")" ./backup/memohub-backup.sh >/dev/null
f="$(ls "$W"/memohub-*.json.gz.age)"
! gzip -t "$f" 2>/dev/null || { echo "backup is not encrypted" >&2; exit 1; }
age -d -i "$W/key" "$f" | gunzip > "$W/backup.json"
docker run --rm --network "$NET" -v "$PWD/backup:/b:ro" -v "$W:/w:ro" postgres:17 \
  bash /b/memohub-restore.sh /w/backup.json "postgresql://postgres:x@$B:5432/postgres" 2>&1 | grep -E "rows restored|ERROR|DETAIL|HINT" | sed 's/.*NOTICE: *//'
q="select string_agg(t || '=' || n, ' ' order by t) from (
  select 'notes' t, count(*) n from memohub.notes union all select 'files', count(*) from memohub.files
  union all select 'projects', count(*) from memohub.projects union all select 'config', count(*) from memohub.config
  union all select 'guides', count(*) from memohub.guides union all select 'superseded', count(*) from memohub.notes where supersedes is not null
  union all select 'fts', count(*) from memohub.notes where fts is not null
  union all select 'entities', count(*) from memohub.entities
  union all select 'note_entities', count(*) from memohub.note_entities
  union all select 'note_embeddings', count(*) from memohub.note_embeddings
  union all select 'forgotten', count(*) from memohub.forgotten
  union all select 'captures', count(*) from memohub.captures
  union all select 'captures_fts', count(*) from memohub.captures where fts is not null
  union all select 'suppressed_chats', count(*) from memohub.suppressed_chats
  union all select 'capture_sources', count(*) from memohub.capture_sources
  union all select 'memory_candidates', count(*) from memohub.memory_candidates
  union all select 'candidates_proposed', count(*) from memohub.memory_candidates where status = 'proposed'
  union all select 'candidate_sources', count(*) from memohub.candidate_sources
  union all select 'candidates_md5', ('x' || left(md5(coalesce(string_agg(to_jsonb(m)::text, '|' order by m.id), '')), 7))::bit(28)::int
    from memohub.memory_candidates m) s"
a="$(docker exec "$A" psql -U postgres -tA -c "$q")"; b="$(docker exec "$B" psql -U postgres -tA -c "$q")"
echo "source:   $a"; echo "restored: $b"
[ "$a" = "$b" ] || { echo "ROUNDTRIP MISMATCH" >&2; exit 1; }
# Forget a note with files after the backup, then restore that backup over it: it must stay gone.
docker exec "$A" psql -U postgres -q -v ON_ERROR_STOP=1 -c \
  "select memohub.forget((select note_id from memohub.files where name = 'lease.pdf'), true),
          memohub.forget_chat('meeting-2026-11-08_10-00', true), memohub.forget_chat('cc-cand1', true)" >/dev/null
out="$(docker run --rm --network "$NET" -v "$PWD/backup:/b:ro" -v "$W:/w:ro" postgres:17 \
  bash /b/memohub-restore.sh /w/backup.json "postgresql://postgres:x@$A:5432/postgres" 2>&1)" \
  || { echo "restore over a forgotten note failed: $out" >&2; exit 1; }
grep -q "memohub.notes: 0 rows restored" <<<"$out" || { echo "unexpected restore: $out" >&2; exit 1; }
grep -q "memohub.captures: 0 rows restored" <<<"$out" || { echo "forgotten chat came back: $out" >&2; exit 1; }
grep -q "memohub.candidate_sources: 0 rows restored" <<<"$out" || { echo "candidate of a forgotten chat came back: $out" >&2; exit 1; }
left="$(docker exec "$A" psql -U postgres -tA -c "select count(*) from memohub.notes where title = 'Договор аренды квартиры'
  union all select count(*) from memohub.files where name in ('lease.pdf', 'Регламент')")"
[ "$(echo $left)" = "0 0" ] && echo "ROUNDTRIP OK" || { echo "forgotten note came back: $left" >&2; exit 1; }
