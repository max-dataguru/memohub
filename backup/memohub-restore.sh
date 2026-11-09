#!/usr/bin/env bash
# Restore a memohub JSON backup into a database that already has the migrations applied
# (scripts/db-push.sh or tests/run-local.sh). Existing rows are kept (on conflict do nothing).
#
#   memohub-restore.sh <backup.json.gz.age | backup.json> <psql connection string>
#   MEMOHUB_BACKUP_KEY  age identity file, default ~/.memohub/backup.key
set -euo pipefail

src="${1:?backup file}"
db="${2:?psql connection string}"
key="${MEMOHUB_BACKUP_KEY:-$HOME/.memohub/backup.key}"

json="$(mktemp)"
case "$src" in
  *.age) age -d -i "$key" "$src" | gunzip > "$json" ;;
  *.gz)  gunzip -c "$src" > "$json" ;;
  *)     cp "$src" "$json" ;;
esac
grep -q '"format" *: *"memohub-json-1"' "$json" || { echo "not a memohub-json-1 backup" >&2; exit 1; }

# The JSON goes into the SQL file as a dollar-quoted literal (not a psql argument: a single
# argument is capped at ~128 KB on Linux, and backups with embeddings are larger).
sql="$(mktemp)"
trap 'rm -f "$json" "$sql"' EXIT
tag="json_$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
{
  cat <<'SQL'
begin;
SQL
  printf 'create temp table _backup on commit drop as select $%s$' "$tag"
  cat "$json"
  printf '$%s$::jsonb as j;\n' "$tag"
  cat <<'SQL'
do $$
declare
  t    text;
  cols text;
  n    int;
begin
  -- Parents first; notes.supersedes points at earlier notes in the same statement.
  -- Entities go before notes: the notes trigger projects note.entities into the graph and
  -- reuses an existing entity by (type, name), so restored ids stay the ones links refer to.
  -- Tombstones go before notes: a trigger skips forgotten notes, and rows hanging off a note
  -- that was not restored are skipped too. Suppressed chats go before captures for the same reason.
  -- Candidates go after notes and captures and only with what they point at.
  -- Backups made before the journal have no capture tables: those loops restore 0 rows.
  foreach t in array array['spaces', 'projects', 'config', 'guides', 'forgotten', 'entities', 'notes', 'files', 'note_entities', 'entity_edges', 'note_embeddings', 'suppressed_chats', 'capture_sources', 'captures', 'memory_candidates', 'candidate_sources', 'distill_runs', 'distill_progress'] loop
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
      from information_schema.columns
     where table_schema = 'memohub' and table_name = t and is_generated = 'NEVER';
    execute format(
      'insert into memohub.%I (%s) select %s from _backup b, '
      'jsonb_populate_recordset(null::memohub.%I, b.j->''tables''->%L) r %s on conflict do nothing',
      t, cols, cols, t, t,
      case t when 'entity_edges' then 'where exists (select 1 from memohub.notes n where n.id = r.evidence_note_id)'
             when 'files' then 'where exists (select 1 from memohub.notes n where n.id = r.note_id)'
             when 'note_entities' then 'where exists (select 1 from memohub.notes n where n.id = r.note_id)'
             when 'note_embeddings' then 'where exists (select 1 from memohub.notes n where n.id = r.note_id)'
             when 'memory_candidates' then 'where (r.target_note_id is null or exists (select 1 from memohub.notes n where n.id = r.target_note_id)) '
                                        || 'and (r.result_note_id is null or exists (select 1 from memohub.notes n where n.id = r.result_note_id))'
             when 'candidate_sources' then 'where exists (select 1 from memohub.memory_candidates m where m.id = r.candidate_id) '
                                        || 'and exists (select 1 from memohub.captures c where c.id = r.capture_id)'
             else '' end);
    get diagnostics n = row_count;
    raise notice 'memohub.%: % rows restored', t, n;
  end loop;
  -- Entities of forgotten notes came back with the old backup; drop those nothing refers to.
  delete from memohub.entities e
   where e.id in (
           select (x->>'entity_id')::uuid from _backup b, jsonb_array_elements(b.j->'tables'->'note_entities') x
            where (x->>'note_id')::uuid in (select id from memohub.forgotten)
           union
           select (x->>k)::uuid from _backup b, jsonb_array_elements(b.j->'tables'->'entity_edges') x,
                  unnest(array['source_entity_id', 'target_entity_id']) k
            where (x->>'evidence_note_id')::uuid in (select id from memohub.forgotten))
     and not exists (select 1 from memohub.note_entities ne where ne.entity_id = e.id)
     and not exists (select 1 from memohub.entity_edges ee where e.id in (ee.source_entity_id, ee.target_entity_id));
  get diagnostics n = row_count;
  raise notice 'memohub.entities: % unreferenced removed', n;
end $$;
commit;
SQL
} > "$sql"
psql "$db" -v ON_ERROR_STOP=1 -X -q -f "$sql"
