-- memohub data export: one JSON document (format memohub-json-1), read by
-- backup/memohub-backup.sh and scripts/mac-backup.sh, restored by backup/memohub-restore.sh.
-- Generated columns (fts) are left out; restore regenerates them.
select json_build_object(
  'format', 'memohub-json-1',
  'exported_at', now(),
  'tier', coalesce((select value from memohub.config where key = 'tier'), 'shared'),
  'guide_version', (select version from memohub.guides where key = 'main'),
  'tables', json_build_object(
    'spaces',   (select coalesce(json_agg(t order by t.slug), '[]') from memohub.spaces t),
    'projects', (select coalesce(json_agg(t order by t.slug), '[]') from memohub.projects t),
    'notes',    (select coalesce(json_agg(to_jsonb(t) - 'fts' order by t.created_at), '[]') from memohub.notes t),
    'files',    (select coalesce(json_agg(to_jsonb(t) - 'fts' order by t.created_at), '[]') from memohub.files t),
    'config',   (select coalesce(json_agg(t order by t.key), '[]') from memohub.config t),
    'guides',   (select coalesce(json_agg(t order by t.key), '[]') from memohub.guides t),
    'entities', (select coalesce(json_agg(t order by t.id), '[]') from memohub.entities t),
    'note_entities', (select coalesce(json_agg(t order by t.note_id, t.entity_id), '[]') from memohub.note_entities t),
    'entity_edges', (select coalesce(json_agg(t order by t.id), '[]') from memohub.entity_edges t),
    'note_embeddings', (select coalesce(json_agg(t order by t.note_id, t.model), '[]') from memohub.note_embeddings t),
    'forgotten', (select coalesce(json_agg(t order by t.id), '[]') from memohub.forgotten t),
    'suppressed_chats', (select coalesce(json_agg(t order by t.chat_ref), '[]') from memohub.suppressed_chats t),
    'capture_sources', (select coalesce(json_agg(t order by t.source, t.device), '[]') from memohub.capture_sources t),
    'captures', (select coalesce(json_agg(to_jsonb(t) - 'fts' order by t.event_at, t.id), '[]') from memohub.captures t),
    'memory_candidates', (select coalesce(json_agg(t order by t.created_at, t.id), '[]') from memohub.memory_candidates t),
    'candidate_sources', (select coalesce(json_agg(t order by t.candidate_id, t.capture_id), '[]') from memohub.candidate_sources t)
  )
);
