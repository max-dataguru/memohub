-- Forgetting a note. Its content goes at once: every version in its supersedes chain, attached
-- files (with extracted text), embeddings, graph links and entities nothing else refers to.
-- A tombstone without content (id, space, project, dates) stays, so restoring an older backup
-- over the database cannot bring the note back.
-- Storage objects cannot be deleted from SQL on Supabase (storage.protect_delete): forget()
-- returns their paths for the Storage API, and orphan_objects() lists whatever is left over.

create table memohub.forgotten (
  id              uuid primary key,          -- id of the forgotten note
  space           text not null,
  project         text,
  note_created_at timestamptz not null,
  forgotten_at    timestamptz not null default now()
);

alter table memohub.forgotten enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on memohub.forgotten from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'memohub_backup') then
    grant select on memohub.forgotten to memohub_backup;
    create policy backup_read on memohub.forgotten for select to memohub_backup using (true);
  end if;
end $$;

-- A forgotten id is never inserted again: the row is silently skipped (restore keeps going).
create function memohub._skip_forgotten()
returns trigger language plpgsql set search_path = memohub, pg_catalog as $$
begin
  if exists (select 1 from forgotten where id = new.id) then return null; end if;
  return new;
end $$;

create trigger notes_skip_forgotten before insert on memohub.notes
  for each row execute function memohub._skip_forgotten();

create function memohub.forget(p_id uuid, p_confirm boolean default false)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  v_ids      uuid[];
  v_notes    jsonb;
  v_files    jsonb;
  v_paths    text[];
  v_entities uuid[];
begin
  if exists (select 1 from forgotten where id = p_id) then
    return jsonb_build_object('ok', true, 'already_forgotten', true, 'id', p_id);
  end if;
  if not exists (select 1 from notes where id = p_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'id', p_id);
  end if;

  -- The whole version chain: older versions hold the same content.
  with recursive chain(id) as (
    select p_id
    union
    select n.id from chain c join notes cur on cur.id = c.id
      join notes n on n.supersedes = c.id or n.id = cur.supersedes
  )
  select array_agg(id) into v_ids from chain;

  select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'status', status,
           'date', to_char(created_at, 'YYYY-MM-DD')) order by created_at)
    into v_notes from notes where id = any (v_ids);
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'kind', kind) order by created_at), '[]'::jsonb),
         coalesce(array_agg(path) filter (where path is not null), '{}')
    into v_files, v_paths from files where note_id = any (v_ids);

  if not coalesce(p_confirm, false) then
    return jsonb_build_object('ok', false, 'error', 'confirm_required', 'notes', v_notes, 'files', v_files,
      'hint', 'Show these versions and files to the user. Only after an explicit yes call '
              || 'memohub.forget(id, true). It cannot be undone; backups keep copies until they expire.');
  end if;

  select array_agg(distinct e) into v_entities from (
    select entity_id from note_entities where note_id = any (v_ids)
    union all
    select unnest(array[source_entity_id, target_entity_id]) from entity_edges
     where evidence_note_id = any (v_ids)
  ) x(e);

  delete from files where note_id = any (v_ids);
  insert into forgotten (id, space, project, note_created_at)
    select id, space, project, created_at from notes where id = any (v_ids);
  -- Embeddings, note_entities and entity_edges go with the notes (on delete cascade).
  delete from notes where id = any (v_ids);
  delete from entities e
   where e.id = any (coalesce(v_entities, '{}'))
     and not exists (select 1 from note_entities ne where ne.entity_id = e.id)
     and not exists (select 1 from entity_edges ee where e.id in (ee.source_entity_id, ee.target_entity_id));

  return jsonb_build_object('ok', true, 'forgotten', v_notes, 'files_removed', v_files,
    'storage_paths', to_jsonb(v_paths))
    || case when cardinality(v_paths) > 0 then jsonb_build_object('hint',
         'Delete these objects from bucket files through the Storage API now if you can '
         || '(supabase storage rm); otherwise the daily cleanup removes them (memohub.orphan_objects).')
       else '{}'::jsonb end;
end $$;

-- Objects in bucket files that no file row refers to: left by forget() or by an upload that was
-- never attached. Only objects older than p_min_age, so an upload in progress is not listed.
create function memohub.orphan_objects(p_min_age interval default interval '1 day')
returns jsonb language plpgsql stable set search_path = memohub, pg_catalog as $$
declare v jsonb := '[]'::jsonb;
begin
  -- Dynamic SQL: the storage schema exists on Supabase but not in plain Postgres tests.
  if to_regclass('storage.objects') is not null then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('path', o.name, 'size', (o.metadata->>'size')::bigint,
               'created_at', o.created_at) order by o.name), '[]'::jsonb)
        from storage.objects o
       where o.bucket_id = 'files' and o.created_at < now() - $1
         and not exists (select 1 from memohub.files f where f.path = o.name)
    $q$ into v using p_min_age;
  end if;
  return v;
end $$;

revoke execute on all functions in schema memohub from public;
