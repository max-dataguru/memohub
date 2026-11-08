-- Contradiction candidates no longer block save(): the note is stored and candidates come back
-- in the result (possible_contradictions). On real data the blocking version stopped 10 of 17
-- saves. conflicts_reviewed=true still suppresses the check.

create or replace function memohub.save(p jsonb)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  v_space text := nullif(trim(p->>'space'),''); v_project text := lower(nullif(trim(p->>'project'),''));
  v_alias text; v_supersedes uuid := nullif(p->>'supersedes','')::uuid;
  v_entities jsonb := coalesce(p->'entities','[]'::jsonb); v_bad jsonb; v_kinds text[];
  v_similar jsonb; v_conflicts jsonb; v_chat text := nullif(trim(p->>'chat_ref'),''); v_id uuid; v_rel jsonb;
begin
  if v_space is null or not exists(select 1 from spaces where slug=v_space) then
    return jsonb_build_object('ok',false,'error','unknown_space','got',v_space,
      'allowed',(select jsonb_agg(slug order by slug) from spaces));
  end if;
  if v_space=any(private_spaces()) and tier()<>'private' then
    return jsonb_build_object('ok',false,'error','private_space','space',v_space,
      'hint','This space is stored only in the private memohub (MCP server memohub-private). Save there, or ask the user.');
  end if;
  if v_project is not null and not exists(select 1 from projects where slug=v_project and space=v_space) then
    select slug into v_alias from projects where space=v_space and v_project=any(select lower(a) from unnest(aliases) a);
    if v_alias is null then return jsonb_build_object('ok',false,'error','unknown_project','got',v_project,
      'space',v_space,'known',(select coalesce(jsonb_agg(slug order by slug),'[]'::jsonb) from projects where space=v_space),
      'hint','Ask the user: pick a known project, save with project=null (inbox), or create it via memohub.add_project.'); end if;
    v_project:=v_alias;
  end if;
  if nullif(trim(p->>'title'),'') is null then return jsonb_build_object('ok',false,'error','missing_title'); end if;
  if jsonb_typeof(v_entities)<>'array' then return jsonb_build_object('ok',false,'error','entities_not_array'); end if;
  select jsonb_agg(e) into v_bad from jsonb_array_elements(v_entities) e
    where jsonb_typeof(e)<>'object' or not(e->>'type'=any(entity_types())) or nullif(trim(e->>'name'),'') is null;
  if v_bad is not null then return jsonb_build_object('ok',false,'error','bad_entities','got',v_bad,
    'allowed_types',to_jsonb(entity_types()),'hint','Each entity is {"type": <allowed type>, "name": <non-empty>}.'); end if;
  if p ? 'relations' and jsonb_typeof(p->'relations')<>'array' then
    return jsonb_build_object('ok',false,'error','relations_not_array');
  end if;
  if p ? 'relations' then
    select jsonb_agg(r) into v_bad from jsonb_array_elements(p->'relations') r
      where jsonb_typeof(r)<>'object' or not((r#>>'{from,type}')=any(entity_types()))
        or not((r#>>'{to,type}')=any(entity_types())) or nullif(trim(r#>>'{from,name}'),'') is null
        or nullif(trim(r#>>'{to,name}'),'') is null or coalesce(r->>'type','') !~ '^[a-z][a-z0-9_]{0,39}$';
    if v_bad is not null then return jsonb_build_object('ok',false,'error','bad_relations','got',v_bad,
      'hint','Each relation has from and to entities ({type,name}) and a lowercase relation type.'); end if;
  end if;
  v_kinds:=sensitive_findings(concat_ws(' ',p->>'title',p->>'body_md',p->>'decisions',p->>'open_questions',p->>'tags',v_entities::text,coalesce(p->'relations','[]'::jsonb)::text));
  if cardinality(v_kinds)>0 then return jsonb_build_object('ok',false,'error','sensitive_data','kinds',to_jsonb(v_kinds),
    'hint','Remove or generalize these values; values are not echoed back.'); end if;
  if v_chat is not null and v_supersedes is null and not coalesce((p->>'new_topic')::boolean,false) then
    select jsonb_agg(jsonb_build_object('id',n.id,'title',n.title,'type',n.type,'date',to_char(n.created_at,'YYYY-MM-DD')) order by n.created_at desc)
      into v_similar from notes n where n.status='active' and n.chat_ref=v_chat and n.space=v_space and n.project is not distinct from v_project;
    if v_similar is not null then return jsonb_build_object('ok',false,'error','same_chat','chat_ref',v_chat,
      'candidates',v_similar,'hint','This chat already saved a note here. Amend it with supersedes, or use new_topic=true for a genuinely different topic.'); end if;
  end if;
  if v_supersedes is null and not coalesce((p->>'new_topic')::boolean,false) then
    select jsonb_agg(c order by (c->>'similarity')::numeric desc) into v_similar from (
      select jsonb_build_object('id',n.id,'title',n.title,'type',n.type,'date',to_char(n.created_at,'YYYY-MM-DD'),
        'similarity',round(extensions.similarity(n.title,trim(p->>'title'))::numeric,2)) c
      from notes n where n.status='active' and n.space=v_space and n.project is not distinct from v_project
       and extensions.similarity(n.title,trim(p->>'title'))>=_cfg_bigint('similar_pct',45)/100.0
      order by extensions.similarity(n.title,trim(p->>'title')) desc limit 3) s;
    if v_similar is not null then return jsonb_build_object('ok',false,'error','similar_exists','candidates',v_similar,
      'hint','Ask the user: amend an existing note with supersedes, or save a separate topic with new_topic=true.'); end if;
  end if;
  -- Heuristic contradiction candidates are reported with the saved note, not used to block it:
  -- on real data most saves in an active project share an entity and some wording.
  v_conflicts:=case when v_supersedes is null and not coalesce((p->>'conflicts_reviewed')::boolean,false)
                    then _conflict_candidates(p,v_space,v_project) else '[]'::jsonb end;
  select coalesce(jsonb_agg(jsonb_build_object('type',t,'name',n) order by t,n),'[]'::jsonb) into v_entities
    from (select distinct on(e->>'type',lower(trim(e->>'name'))) e->>'type' t,trim(e->>'name') n
      from jsonb_array_elements(v_entities) e order by e->>'type',lower(trim(e->>'name'))) x;
  insert into notes(space,project,type,title,body_md,decisions,open_questions,tags,entities,source,device,supersedes,chat_ref,chat_url)
  values(v_space,v_project,coalesce(nullif(p->>'type',''),'session'),trim(p->>'title'),coalesce(p->>'body_md',''),
    coalesce(p->'decisions','[]'::jsonb),coalesce(p->'open_questions','[]'::jsonb),
    coalesce(array(select distinct lower(trim(t)) from jsonb_array_elements_text(p->'tags') t where trim(t)<>''),'{}'),
    v_entities,coalesce(nullif(p->>'source',''),'manual'),nullif(p->>'device',''),v_supersedes,v_chat,nullif(trim(p->>'chat_url'),''))
  returning id into v_id;
  v_rel:=_add_entity_edges(v_id,p->'relations');
  if not coalesce((v_rel->>'ok')::boolean,true) then raise exception 'invalid relations'; end if;
  if v_supersedes is not null then update notes set status='superseded',updated_at=now() where id=v_supersedes; end if;
  return jsonb_build_object('ok',true,'id',v_id,'space',v_space,'project',v_project,'inbox',v_project is null,
    'chat_ref',v_chat,'tier',tier(),'relations_created',coalesce((v_rel->>'created')::int,0))
    || case when jsonb_array_length(v_conflicts)>0 then jsonb_build_object(
         'possible_contradictions',v_conflicts,
         'hint','Saved. These active notes share an entity and wording with it: read them and tell the user '
                || 'if one is now outdated (then amend that note with supersedes).') else '{}'::jsonb end;
end $$;

revoke execute on all functions in schema memohub from public;
