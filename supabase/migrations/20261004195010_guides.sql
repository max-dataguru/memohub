-- Client guide stored in the database.
-- Clients (ChatGPT, claude.ai, Codex) keep only a short bootstrap and read the current rules with
-- memohub.guide(). The text comes from clients/guide.md and is written by scripts/sync-guide.sh;
-- nothing else may change this table (stated in the guide itself; sync-guide.sh --check detects drift).

create table memohub.guides (
  key        text primary key,
  version    int not null default 1,
  sha256     text not null,
  body       text not null,
  updated_at timestamptz not null default now()
);
alter table memohub.guides enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on memohub.guides from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'memohub_backup') then
    grant select on memohub.guides to memohub_backup;
    create policy backup_read on memohub.guides for select to memohub_backup using (true);
  end if;
end $$;

create or replace function memohub.guide()
returns jsonb
language sql stable
set search_path = memohub, pg_catalog
as $$
  select coalesce(
    (select jsonb_build_object('version', g.version, 'sha256', left(g.sha256, 12),
                               'updated_at', g.updated_at, 'tier', tier(), 'text', g.body)
       from guides g where g.key = 'main'),
    jsonb_build_object('ok', false, 'error', 'guide_missing',
      'hint', 'The guide has not been synced yet. Tell the user to run scripts/sync-guide.sh.')
  );
$$;

-- Catalog: also reports which guide version is live.
create or replace function memohub.catalog()
returns jsonb
language sql stable
set search_path = memohub, pg_catalog
as $$
  select jsonb_build_object(
    'tier', tier(),
    'private_spaces', to_jsonb(private_spaces()),
    'storage', storage_usage(),
    'guide', (select jsonb_build_object('version', g.version, 'sha256', left(g.sha256, 12),
                                        'updated_at', g.updated_at)
                from guides g where g.key = 'main'),
    'spaces', (
      select coalesce(jsonb_agg(sp order by sp->>'slug'), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'slug', s.slug,
          'title', s.title,
          'inbox', (select count(*) from notes n
                     where n.space = s.slug and n.project is null and n.status = 'active'),
          'projects', coalesce((
            select jsonb_agg(jsonb_build_object(
                     'slug', p.slug, 'title', p.title, 'aliases', p.aliases,
                     'notes', (select count(*) from notes n
                                where n.project = p.slug and n.status = 'active'))
                   order by p.slug)
            from projects p where p.space = s.slug), '[]'::jsonb)
        ) as sp
        from spaces s
      ) x),
    'tags', (
      select coalesce(jsonb_agg(jsonb_build_object('tag', tag, 'notes', cnt)
                                order by cnt desc, tag), '[]'::jsonb)
      from (select t as tag, count(*) as cnt
              from notes n, unnest(n.tags) t
             where n.status = 'active'
             group by t order by count(*) desc, t limit 50) t),
    'entities', (
      select coalesce(jsonb_agg(jsonb_build_object('type', type, 'name', name, 'notes', cnt)
                                order by cnt desc, name), '[]'::jsonb)
      from (select e->>'type' as type, min(e->>'name') as name, count(*) as cnt
              from notes n, jsonb_array_elements(n.entities) e
             where n.status = 'active'
             group by e->>'type', lower(e->>'name')
             order by count(*) desc, min(e->>'name') limit 50) e),
    'entity_types', to_jsonb(entity_types()),
    'hint', 'project = null means inbox; create projects only with the user''s consent via '
            || 'memohub.add_project. Reuse existing tags and entity names before creating new ones.'
            || case when tier() = 'private' then ''
                    else ' Spaces in private_spaces are stored only in memohub-private.' end,
    'files_hint', 'Files: memohub.check_upload(size_bytes, sha256) BEFORE uploading (refuses over quota, '
            || 'warns near it — tell the user), upload to bucket "files", then '
            || 'memohub.attach_file({note_id, path, name, summary, extracted_text, sha256}). '
            || 'Company documents: attach_file({note_id, url, name, summary}) — no upload.'
  );
$$;

revoke execute on all functions in schema memohub from public;
