-- Amending notes instead of piling up near-duplicates.
-- save() refuses a note whose title is close to an active note in the same space/project
-- (pg_trgm similarity, config 'similar_pct', default 45) unless it supersedes one or is marked
-- "new_topic": true. The client then writes one merged version with "supersedes"; the old one
-- stays as history (status superseded), visible through history(id).
-- notes.chat_ref identifies the chat a note came from (Claude Code session id, or a label the
-- chat model makes up on its first save and reuses); a second save from the same chat into the
-- same space/project is refused the same way, so later additions amend the existing note.

create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

alter table memohub.notes add column chat_ref text, add column chat_url text;
create index notes_chat_ref_idx on memohub.notes (chat_ref) where chat_ref is not null;

create or replace function memohub.save(p jsonb)
returns jsonb
language plpgsql
set search_path = memohub, pg_catalog
as $$
declare
  v_space      text := nullif(trim(p->>'space'), '');
  v_project    text := lower(nullif(trim(p->>'project'), ''));
  v_alias      text;
  v_supersedes uuid := nullif(p->>'supersedes', '')::uuid;
  v_entities   jsonb := coalesce(p->'entities', '[]'::jsonb);
  v_bad        jsonb;
  v_kinds      text[];
  v_similar    jsonb;
  v_chat       text := nullif(trim(p->>'chat_ref'), '');
  v_id         uuid;
begin
  if v_space is null or not exists (select 1 from spaces where slug = v_space) then
    return jsonb_build_object('ok', false, 'error', 'unknown_space', 'got', v_space,
      'allowed', (select jsonb_agg(slug order by slug) from spaces));
  end if;

  if v_space = any (private_spaces()) and tier() <> 'private' then
    return jsonb_build_object('ok', false, 'error', 'private_space', 'space', v_space,
      'hint', 'This space is stored only in the private memohub (MCP server memohub-private). '
              || 'Save there, or ask the user.');
  end if;

  if v_project is not null
     and not exists (select 1 from projects where slug = v_project and space = v_space) then
    select slug into v_alias
      from projects
     where space = v_space
       and v_project = any (select lower(a) from unnest(aliases) a);
    if v_alias is null then
      return jsonb_build_object('ok', false, 'error', 'unknown_project',
        'got', v_project, 'space', v_space,
        'known', (select coalesce(jsonb_agg(slug order by slug), '[]'::jsonb)
                    from projects where space = v_space),
        'hint', 'Ask the user: pick a known project, save with project=null (inbox), '
                || 'or create it via memohub.add_project.');
    end if;
    v_project := v_alias;
  end if;

  if nullif(trim(p->>'title'), '') is null then
    return jsonb_build_object('ok', false, 'error', 'missing_title');
  end if;

  if jsonb_typeof(v_entities) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'entities_not_array');
  end if;
  select jsonb_agg(e) into v_bad
    from jsonb_array_elements(v_entities) e
   where jsonb_typeof(e) <> 'object'
      or not (e->>'type' = any (entity_types()))
      or nullif(trim(e->>'name'), '') is null;
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'error', 'bad_entities', 'got', v_bad,
      'allowed_types', to_jsonb(entity_types()),
      'hint', 'Each entity is {"type": <allowed type>, "name": <non-empty>}.');
  end if;

  v_kinds := sensitive_findings(concat_ws(' ', p->>'title', p->>'body_md',
                                          p->>'decisions', p->>'open_questions',
                                          p->>'tags', v_entities::text));
  if cardinality(v_kinds) > 0 then
    return jsonb_build_object('ok', false, 'error', 'sensitive_data', 'kinds', to_jsonb(v_kinds),
      'hint', 'Remove or generalize these values (e.g. "карта Тинькофф", "паспорт продлён до 2031") '
              || 'and save again. Values are not echoed back.');
  end if;

  -- Same chat already saved into this space/project: amend that note.
  if v_chat is not null and v_supersedes is null and not coalesce((p->>'new_topic')::boolean, false) then
    select jsonb_agg(jsonb_build_object('id', n.id, 'title', n.title, 'type', n.type,
                     'date', to_char(n.created_at, 'YYYY-MM-DD')) order by n.created_at desc)
      into v_similar
      from notes n
     where n.status = 'active' and n.chat_ref = v_chat
       and n.space = v_space and n.project is not distinct from v_project;
    if v_similar is not null then
      return jsonb_build_object('ok', false, 'error', 'same_chat', 'chat_ref', v_chat,
        'candidates', v_similar,
        'hint', 'This chat already saved a note here. Amend it: memohub.get(id), write ONE merged '
                || 'version (keep what is still true, add the new, drop the outdated, list removals '
                || 'under "## Изменения"), save with "supersedes": id. A genuinely different topic '
                || 'from the same chat: "new_topic": true.');
    end if;
  end if;

  -- A note on the same topic already exists: amend it instead of adding a near-duplicate.
  if v_supersedes is null and not coalesce((p->>'new_topic')::boolean, false) then
    select jsonb_agg(c order by (c->>'similarity')::numeric desc) into v_similar
      from (select jsonb_build_object('id', n.id, 'title', n.title, 'type', n.type,
                     'date', to_char(n.created_at, 'YYYY-MM-DD'),
                     'similarity', round(extensions.similarity(n.title, trim(p->>'title'))::numeric, 2)) c
              from notes n
             where n.status = 'active'
               and n.space = v_space
               and n.project is not distinct from v_project
               and extensions.similarity(n.title, trim(p->>'title')) >= _cfg_bigint('similar_pct', 45) / 100.0
             order by extensions.similarity(n.title, trim(p->>'title')) desc
             limit 3) s;
    if v_similar is not null then
      return jsonb_build_object('ok', false, 'error', 'similar_exists', 'candidates', v_similar,
        'hint', 'Ask the user: amend an existing note — memohub.get(id), write ONE merged version '
                || '(keep facts that are still true, add the new ones, drop what is outdated or '
                || 'contradicted, list removals under "## Изменения"), save it with "supersedes": id — '
                || 'or save as a separate topic with "new_topic": true.');
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('type', t, 'name', n) order by t, n), '[]'::jsonb)
    into v_entities
    from (select distinct on (e->>'type', lower(trim(e->>'name')))
                 e->>'type' as t, trim(e->>'name') as n
            from jsonb_array_elements(v_entities) e
           order by e->>'type', lower(trim(e->>'name'))) x;

  insert into notes (space, project, type, title, body_md, decisions, open_questions,
                     tags, entities, source, device, supersedes, chat_ref, chat_url)
  values (
    v_space,
    v_project,
    coalesce(nullif(p->>'type', ''), 'session'),
    trim(p->>'title'),
    coalesce(p->>'body_md', ''),
    coalesce(p->'decisions', '[]'::jsonb),
    coalesce(p->'open_questions', '[]'::jsonb),
    coalesce(array(select distinct lower(trim(t))
                     from jsonb_array_elements_text(p->'tags') t
                    where trim(t) <> ''), '{}'),
    v_entities,
    coalesce(nullif(p->>'source', ''), 'manual'),
    nullif(p->>'device', ''),
    v_supersedes,
    v_chat,
    nullif(trim(p->>'chat_url'), '')
  )
  returning id into v_id;

  if v_supersedes is not null then
    update notes set status = 'superseded', updated_at = now() where id = v_supersedes;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'space', v_space,
                            'project', v_project, 'inbox', v_project is null,
                            'chat_ref', v_chat, 'tier', tier());
end;
$$;

-- Version chain of a note: older versions it superseded and newer versions that replaced it.
create or replace function memohub.history(p_id uuid)
returns jsonb
language sql stable
set search_path = memohub, pg_catalog
as $$
  with recursive
    back as (
      select n.id, n.supersedes, 0 as step from notes n where n.id = p_id
      union all
      select o.id, o.supersedes, b.step - 1 from notes o join back b on o.id = b.supersedes
    ),
    fwd as (
      select n.id, 0 as step from notes n where n.id = p_id
      union all
      select c.id, f.step + 1 from notes c join fwd f on c.supersedes = f.id
    ),
    chain as (select id, step from back union select id, step from fwd)
  select coalesce(
    (select jsonb_agg(jsonb_build_object(
              'id', n.id, 'step', ch.step, 'status', n.status, 'title', n.title,
              'date', to_char(n.created_at, 'YYYY-MM-DD HH24:MI'), 'source', n.source)
            order by ch.step)
       from chain ch join notes n on n.id = ch.id),
    jsonb_build_object('ok', false, 'error', 'not_found', 'id', p_id)
  );
$$;

-- Everything saved from one chat.
create or replace function memohub.by_chat(p_chat_ref text, p_include_superseded boolean default false)
returns jsonb
language sql stable
set search_path = memohub, pg_catalog
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', n.id, 'space', n.space, 'project', n.project, 'type', n.type, 'title', n.title,
           'status', n.status, 'date', to_char(n.created_at, 'YYYY-MM-DD HH24:MI'), 'chat_url', n.chat_url)
         order by n.created_at), '[]'::jsonb)
    from notes n
   where n.chat_ref = p_chat_ref and (p_include_superseded or n.status = 'active');
$$;

revoke execute on all functions in schema memohub from public;
