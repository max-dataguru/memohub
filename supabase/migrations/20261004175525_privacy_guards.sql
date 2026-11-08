-- Privacy guards.
-- 1. save() rejects notes containing card numbers, IBANs, passport / SNILS numbers or
--    credentials. Kinds are reported, values are never echoed back.
-- 2. Private tier: the same schema runs in two projects. Spaces listed in
--    config 'private_spaces' (default: medicine) can only be written where
--    config 'tier' = 'private'; the shared project has no such row.

create table brain.config (
  key   text primary key,
  value text not null
);
alter table brain.config enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on brain.config from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'brain_backup') then
    grant select on brain.config to brain_backup;
    create policy backup_read on brain.config for select to brain_backup using (true);
  end if;
end $$;

create or replace function brain.tier()
returns text
language sql stable
set search_path = brain, pg_catalog
as $$ select coalesce((select value from config where key = 'tier'), 'shared') $$;

create or replace function brain.private_spaces()
returns text[]
language sql stable
set search_path = brain, pg_catalog
as $$
  select coalesce(
    (select array(select trim(s) from unnest(string_to_array(value, ',')) s)
       from config where key = 'private_spaces'),
    array['medicine'])
$$;

-- Sensitive data detection ---------------------------------------------------

create or replace function brain._luhn_ok(digits text)
returns boolean
language plpgsql immutable
as $$
declare
  s   int := 0;
  d   int;
  alt boolean := false;
begin
  for i in reverse length(digits)..1 loop
    d := substr(digits, i, 1)::int;
    if alt then
      d := d * 2;
      if d > 9 then d := d - 9; end if;
    end if;
    s := s + d;
    alt := not alt;
  end loop;
  return s % 10 = 0;
end;
$$;

create or replace function brain._iban_ok(raw text)
returns boolean
language plpgsql immutable
as $$
declare
  v   text := upper(regexp_replace(raw, '\s', '', 'g'));
  r   text;
  rem int := 0;
  c   text;
begin
  if length(v) not between 15 and 34 then
    return false;
  end if;
  r := substr(v, 5) || substr(v, 1, 4);
  foreach c in array regexp_split_to_array(r, '') loop
    if c ~ '\d' then
      rem := (rem * 10 + c::int) % 97;
    else
      rem := (rem * 100 + ascii(c) - 55) % 97;
    end if;
  end loop;
  return rem = 1;
end;
$$;

create or replace function brain.sensitive_findings(t text)
returns text[]
language plpgsql immutable
set search_path = brain, pg_catalog
as $$
declare
  kinds text[] := '{}';
  m     text;
  pat   text;
begin
  if t is null or t = '' then
    return kinds;
  end if;

  for m in select (regexp_matches(t, '(?:\d[ -]?){12,18}\d', 'g'))[1] loop
    if length(regexp_replace(m, '\D', '', 'g')) between 13 and 19
       and _luhn_ok(regexp_replace(m, '\D', '', 'g')) then
      kinds := array_append(kinds, 'card_number');
      exit;
    end if;
  end loop;

  for m in select (regexp_matches(t, '\m[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}', 'g'))[1] loop
    if _iban_ok(m) then
      kinds := array_append(kinds, 'iban');
      exit;
    end if;
  end loop;

  if t ~* '(паспорт|passport)\D{0,30}\d{2} ?\d{2} ?\d{6}' then
    kinds := array_append(kinds, 'passport_number');
  end if;

  if t ~ '\m\d{3}-\d{3}-\d{3}[ -]\d{2}\M' then
    kinds := array_append(kinds, 'snils');
  end if;

  foreach pat in array array[
    'sk-[A-Za-z0-9_-]{20,}',                              -- OpenAI / Anthropic style keys
    'sk_(live|test)_[A-Za-z0-9]{16,}',                    -- Stripe
    'gh[pousr]_[A-Za-z0-9]{30,}', 'github_pat_[A-Za-z0-9_]{30,}',
    'xox[abprs]-[A-Za-z0-9-]{10,}',                       -- Slack
    'AKIA[0-9A-Z]{16}',                                   -- AWS access key
    'sbp_[a-f0-9]{40}',                                   -- Supabase access token
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',  -- JWT
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s@/]+@'             -- URL with user:password
  ] loop
    if t ~ pat then
      kinds := array_append(kinds, 'credential');
      exit;
    end if;
  end loop;
  if t ~* '(password|passwd|pwd|пароль)\s*[:=]\s*\S{4,}' then
    kinds := array_append(kinds, 'credential');
  end if;

  return array(select distinct k from unnest(kinds) k order by k);
end;
$$;

-- save() with both guards ------------------------------------------------------

create or replace function brain.save(p jsonb)
returns jsonb
language plpgsql
set search_path = brain, pg_catalog
as $$
declare
  v_space      text := nullif(trim(p->>'space'), '');
  v_project    text := lower(nullif(trim(p->>'project'), ''));
  v_alias      text;
  v_supersedes uuid := nullif(p->>'supersedes', '')::uuid;
  v_entities   jsonb := coalesce(p->'entities', '[]'::jsonb);
  v_bad        jsonb;
  v_kinds      text[];
  v_id         uuid;
begin
  if v_space is null or not exists (select 1 from spaces where slug = v_space) then
    return jsonb_build_object('ok', false, 'error', 'unknown_space', 'got', v_space,
      'allowed', (select jsonb_agg(slug order by slug) from spaces));
  end if;

  if v_space = any (private_spaces()) and tier() <> 'private' then
    return jsonb_build_object('ok', false, 'error', 'private_space', 'space', v_space,
      'hint', 'This space is stored only in the private brain (MCP server brain-private). '
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
                || 'or create it via brain.add_project.');
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

  select coalesce(jsonb_agg(jsonb_build_object('type', t, 'name', n) order by t, n), '[]'::jsonb)
    into v_entities
    from (select distinct on (e->>'type', lower(trim(e->>'name')))
                 e->>'type' as t, trim(e->>'name') as n
            from jsonb_array_elements(v_entities) e
           order by e->>'type', lower(trim(e->>'name'))) x;

  insert into notes (space, project, type, title, body_md, decisions, open_questions,
                     tags, entities, source, device, supersedes)
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
    v_supersedes
  )
  returning id into v_id;

  if v_supersedes is not null then
    update notes set status = 'superseded', updated_at = now() where id = v_supersedes;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'space', v_space,
                            'project', v_project, 'inbox', v_project is null,
                            'tier', tier());
end;
$$;

-- catalog() tells the model which brain it is talking to.
create or replace function brain.catalog()
returns jsonb
language sql stable
set search_path = brain, pg_catalog
as $$
  select jsonb_build_object(
    'tier', tier(),
    'private_spaces', to_jsonb(private_spaces()),
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
            || 'brain.add_project. Reuse existing tags and entity names before creating new ones.'
            || case when tier() = 'private' then ''
                    else ' Spaces in private_spaces are stored only in brain-private.' end
  );
$$;

revoke execute on all functions in schema brain from public;
