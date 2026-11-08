-- Typed entity graph, save-time conflict candidates, and opt-in vector search.
-- Embeddings are supplied by clients; this migration never sends note text to a provider.

create extension if not exists vector with schema extensions;

-- Graph ---------------------------------------------------------------------

create table memohub.entities (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type = any (memohub.entity_types())),
  name text not null check (length(trim(name)) > 0),
  normalized_name text generated always as (lower(trim(name))) stored,
  created_at timestamptz not null default now(),
  unique (entity_type, normalized_name)
);

create table memohub.note_entities (
  note_id uuid not null references memohub.notes(id) on delete cascade,
  entity_id uuid not null references memohub.entities(id) on delete cascade,
  edge_type text not null default 'mentions' check (edge_type ~ '^[a-z][a-z0-9_]{0,39}$'),
  primary key (note_id, entity_id, edge_type)
);
create index note_entities_entity_idx on memohub.note_entities(entity_id, note_id);

create table memohub.entity_edges (
  id uuid primary key default gen_random_uuid(),
  source_entity_id uuid not null references memohub.entities(id) on delete cascade,
  target_entity_id uuid not null references memohub.entities(id) on delete cascade,
  relation_type text not null check (relation_type ~ '^[a-z][a-z0-9_]{0,39}$'),
  evidence_note_id uuid not null references memohub.notes(id) on delete cascade,
  created_at timestamptz not null default now(),
  check (source_entity_id <> target_entity_id),
  unique (source_entity_id, target_entity_id, relation_type, evidence_note_id)
);
create index entity_edges_source_idx on memohub.entity_edges(source_entity_id, relation_type);
create index entity_edges_target_idx on memohub.entity_edges(target_entity_id, relation_type);

alter table memohub.entities enable row level security;
alter table memohub.note_entities enable row level security;
alter table memohub.entity_edges enable row level security;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on memohub.entities, memohub.note_entities, memohub.entity_edges from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'memohub_backup') then
    grant select on memohub.entities, memohub.note_entities, memohub.entity_edges to memohub_backup;
    create policy backup_read on memohub.entities for select to memohub_backup using (true);
    create policy backup_read on memohub.note_entities for select to memohub_backup using (true);
    create policy backup_read on memohub.entity_edges for select to memohub_backup using (true);
  end if;
end $$;

-- Idempotently project the existing JSONB entity annotations into graph nodes/edges.
create or replace function memohub._project_note_entities(p_note_id uuid, p_entities jsonb)
returns void language plpgsql set search_path = memohub, pg_catalog as $$
declare e jsonb; v_entity uuid;
begin
  for e in select value from jsonb_array_elements(coalesce(p_entities, '[]'::jsonb)) loop
    insert into entities(entity_type, name)
    values (e->>'type', trim(e->>'name'))
    on conflict (entity_type, normalized_name) do update set name = entities.name
    returning id into v_entity;
    insert into note_entities(note_id, entity_id, edge_type)
      values (p_note_id, v_entity, 'mentions') on conflict do nothing;
  end loop;
end $$;

select memohub._project_note_entities(n.id, n.entities) from memohub.notes n;

create or replace function memohub._sync_note_entities()
returns trigger language plpgsql set search_path = memohub, pg_catalog as $$
begin
  delete from note_entities where note_id = new.id;
  perform memohub._project_note_entities(new.id, new.entities);
  return new;
end $$;
create trigger notes_entity_graph_sync after insert or update of entities on memohub.notes
  for each row execute function memohub._sync_note_entities();

-- Relations are explicit save input: [{from:{type,name}, type, to:{type,name}}].
create or replace function memohub._add_entity_edges(p_note_id uuid, p_relations jsonb)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare r jsonb; v_from uuid; v_to uuid; v_count int := 0;
begin
  if p_relations is null then return jsonb_build_object('ok', true, 'created', 0); end if;
  if jsonb_typeof(p_relations) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'relations_not_array');
  end if;
  for r in select value from jsonb_array_elements(p_relations) loop
    if jsonb_typeof(r) <> 'object'
       or not ((r#>>'{from,type}') = any(memohub.entity_types()))
       or not ((r#>>'{to,type}') = any(memohub.entity_types()))
       or nullif(trim(r#>>'{from,name}'), '') is null
       or nullif(trim(r#>>'{to,name}'), '') is null
       or coalesce(r->>'type','') !~ '^[a-z][a-z0-9_]{0,39}$' then
      return jsonb_build_object('ok', false, 'error', 'bad_relation', 'got', r,
        'hint', 'Use {"from":{"type":"person","name":"..."},"type":"works_with","to":{"type":"org","name":"..."}}.');
    end if;
    insert into entities(entity_type,name) values(r#>>'{from,type}',trim(r#>>'{from,name}') )
      on conflict(entity_type,normalized_name) do update set name=entities.name returning id into v_from;
    insert into entities(entity_type,name) values(r#>>'{to,type}',trim(r#>>'{to,name}') )
      on conflict(entity_type,normalized_name) do update set name=entities.name returning id into v_to;
    insert into entity_edges(source_entity_id,target_entity_id,relation_type,evidence_note_id)
      values(v_from,v_to,r->>'type',p_note_id) on conflict do nothing;
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('ok',true,'created',v_count);
end $$;

create or replace function memohub.graph(p_type text, p_name text, p_limit int default 25)
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  with root as (
    select id, entity_type, name from entities
    where (p_type is null or entity_type=p_type) and normalized_name=lower(trim(p_name))
    order by id limit 1
  ), related as (
    select e.id, e.entity_type, e.name, ne.edge_type as relation,
           n.id as note_id, n.title as note_title, n.created_at
      from root r join note_entities ne on ne.entity_id=r.id
      join notes n on n.id=ne.note_id and n.status='active'
      join entities e on e.id=r.id
    union all
    select e.id, e.entity_type, e.name, ee.relation_type,
           n.id, n.title, n.created_at
      from root r join entity_edges ee on ee.source_entity_id=r.id or ee.target_entity_id=r.id
      join entities e on e.id=case when ee.source_entity_id=r.id then ee.target_entity_id else ee.source_entity_id end
      join notes n on n.id=ee.evidence_note_id and n.status='active'
  )
  select jsonb_build_object('entity', (select to_jsonb(root) from root),
    'edges', coalesce((select jsonb_agg(jsonb_build_object('entity_id',id,'type',entity_type,'name',name,
      'relation',relation,'note_id',note_id,'note_title',note_title) order by created_at desc)
      from (select * from related order by created_at desc limit least(greatest(coalesce(p_limit,25),1),100)) limited),'[]'::jsonb))
$$;

-- Embeddings are versioned by model and dimensions; the vector type is intentionally
-- unbounded so the chosen provider/model can be configured without a schema rewrite.
create table memohub.note_embeddings (
  note_id uuid not null references memohub.notes(id) on delete cascade,
  model text not null check (length(trim(model)) > 0),
  embedding extensions.vector not null,
  updated_at timestamptz not null default now(),
  primary key(note_id, model)
);
alter table memohub.note_embeddings enable row level security;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on memohub.note_embeddings from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'memohub_backup') then
    grant select on memohub.note_embeddings to memohub_backup;
    create policy backup_read on memohub.note_embeddings for select to memohub_backup using (true);
  end if;
end $$;

create or replace function memohub.put_embedding(p_note_id uuid, p_model text, p_embedding extensions.vector)
returns jsonb language plpgsql set search_path=memohub,pg_catalog as $$
begin
  if p_embedding is null or nullif(trim(p_model),'') is null then
    return jsonb_build_object('ok',false,'error','missing_embedding_or_model');
  end if;
  if exists(select 1 from note_embeddings e where e.model=trim(p_model)
      and extensions.vector_dims(e.embedding)<>extensions.vector_dims(p_embedding)) then
    return jsonb_build_object('ok',false,'error','embedding_dimensions_mismatch',
      'hint','Use one fixed vector dimension for each embedding model.');
  end if;
  if not exists(select 1 from notes where id=p_note_id) then
    return jsonb_build_object('ok',false,'error','unknown_note','id',p_note_id);
  end if;
  insert into note_embeddings(note_id,model,embedding,updated_at)
    values(p_note_id,trim(p_model),p_embedding,now())
    on conflict(note_id,model) do update set embedding=excluded.embedding,updated_at=now();
  return jsonb_build_object('ok',true,'note_id',p_note_id,'model',trim(p_model),
    'dimensions',extensions.vector_dims(p_embedding));
end $$;

-- Candidate scoring is deliberately not a contradiction verdict. It combines shared
-- entities with textual overlap in decisions/body and asks the caller to review candidates.
create or replace function memohub._conflict_candidates(p jsonb, p_space text, p_project text)
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  with incoming_entities as (
    select lower(trim(e->>'name')) name from jsonb_array_elements(coalesce(p->'entities','[]'::jsonb)) e
  ), incoming as (
    select concat_ws(' ', p->>'title', p->>'decisions', p->>'body_md') claim
  ), scored as (
    select n.id,n.title,n.type,n.space,n.project,n.created_at,
      extensions.similarity(concat_ws(' ',n.decisions,n.body_md), i.claim) sim,
      exists(select 1 from jsonb_array_elements(n.entities) e join incoming_entities ie
        on ie.name=lower(trim(e->>'name'))) shared_entity
    from notes n cross join incoming i
    where n.status='active' and n.space=p_space and n.project is not distinct from p_project
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'type',type,
      'date',to_char(created_at,'YYYY-MM-DD'),'similarity',round(sim::numeric,2),
      'shared_entity',shared_entity) order by sim desc,created_at desc),'[]'::jsonb)
  from (select * from scored where shared_entity and sim >= 0.18 order by sim desc limit 5) c
$$;

-- Preserve the established save contract while adding candidate review and graph relation input.
drop function memohub.save(jsonb);
create function memohub.save(p jsonb)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  v_space text := nullif(trim(p->>'space'),''); v_project text := lower(nullif(trim(p->>'project'),''));
  v_alias text; v_supersedes uuid := nullif(p->>'supersedes','')::uuid;
  v_entities jsonb := coalesce(p->'entities','[]'::jsonb); v_bad jsonb; v_kinds text[];
  v_similar jsonb; v_chat text := nullif(trim(p->>'chat_ref'),''); v_id uuid; v_rel jsonb;
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
  if v_supersedes is null and not coalesce((p->>'conflicts_reviewed')::boolean,false) then
    v_similar:=_conflict_candidates(p,v_space,v_project);
    if jsonb_array_length(v_similar)>0 then return jsonb_build_object('ok',false,'error','possible_contradiction',
      'candidates',v_similar,'hint','These are heuristic candidates, not confirmed contradictions. Review each note; amend with supersedes, or after review retry with conflicts_reviewed=true.'); end if;
  end if;
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
    'chat_ref',v_chat,'tier',tier(),'relations_created',coalesce((v_rel->>'created')::int,0));
end $$;

-- The original signature is retained; semantic ranking is activated only when callers
-- provide a query vector and matching model. Keyword-only behavior remains unchanged.
create function memohub.search(
  q text, p_space text, p_project text, p_since date,
  p_limit int, p_include_superseded boolean,
  p_query_embedding extensions.vector, p_embedding_model text
) returns jsonb language plpgsql stable set search_path=memohub,pg_catalog as $$
declare
  v_lim int:=least(greatest(coalesce(p_limit,8),1),25); v_text text:=nullif(trim(q),'');
  v_q tsquery; v_mode text:='recent'; v_total int; v_items jsonb;
begin
  if p_query_embedding is not null and nullif(trim(p_embedding_model),'') is null then
    return jsonb_build_object('ok',false,'error','embedding_model_required');
  end if;
  if p_query_embedding is not null and exists(select 1 from note_embeddings e where e.model=p_embedding_model
      and extensions.vector_dims(e.embedding)<>extensions.vector_dims(p_query_embedding)) then
    return jsonb_build_object('ok',false,'error','embedding_dimensions_mismatch');
  end if;
  if v_text is not null then v_q:=websearch_to_tsquery('russian',v_text); v_mode:='fulltext'; end if;
  if p_query_embedding is not null then v_mode:='hybrid'; end if;
  with candidates as (
    select n.id,
      greatest(coalesce(ts_rank(n.fts,v_q),0),coalesce((select max(ts_rank(f.fts,v_q)) from files f where f.note_id=n.id),0)) lexical,
      (select min(e.embedding OPERATOR(extensions.<=>) p_query_embedding) from note_embeddings e where e.note_id=n.id and e.model=p_embedding_model) distance
    from notes n where (p_space is null or n.space=p_space) and (p_project is null or n.project=lower(p_project))
      and (p_since is null or n.created_at>=p_since) and (p_include_superseded or n.status='active')
      and (p_query_embedding is null or exists(select 1 from note_embeddings e where e.note_id=n.id and e.model=p_embedding_model)
        or (v_text is not null and (n.fts @@ v_q or exists(select 1 from files f where f.note_id=n.id and f.fts @@ v_q))))
      and (v_text is null or n.fts @@ v_q or exists(select 1 from files f where f.note_id=n.id and f.fts @@ v_q)
        or (p_query_embedding is not null))
  ), ranked as (select id,lexical,distance from candidates)
  select count(*) into v_total from ranked;
  if v_total=0 and v_text is not null and p_query_embedding is null then
    select string_agg(quote_literal(lexeme),' | ')::tsquery into v_q from unnest(tsvector_to_array(to_tsvector('russian',v_text))) lexeme;
    if v_q is not null then
      v_mode:='fulltext_any';
      select count(*) into v_total from notes n where (n.fts @@ v_q or exists(select 1 from files f where f.note_id=n.id and f.fts @@ v_q))
        and (p_space is null or n.space=p_space) and (p_project is null or n.project=lower(p_project))
        and (p_since is null or n.created_at>=p_since) and (p_include_superseded or n.status='active');
    end if;
  end if;
  if v_total=0 and v_text is not null and p_query_embedding is null then v_mode:='substring';
    select count(*) into v_total from notes n where (n.title ilike '%'||v_text||'%' or n.body_md ilike '%'||v_text||'%'
      or exists(select 1 from files f where f.note_id=n.id and f.name ilike '%'||v_text||'%'))
      and (p_space is null or n.space=p_space) and (p_project is null or n.project=lower(p_project))
      and (p_since is null or n.created_at>=p_since) and (p_include_superseded or n.status='active');
  end if;
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into v_items from (
    select row_number() over(order by case when v_mode='hybrid' then (coalesce(c.lexical,0)/(1+coalesce(c.lexical,0))) + (1/(1+coalesce(c.distance,1)))
       when v_mode in ('fulltext','fulltext_any') then c.lexical else 0 end desc,n.created_at desc) ord,
      jsonb_build_object('id',n.id,'space',n.space,'project',n.project,'type',n.type,'title',n.title,'status',n.status,'source',n.source,
       'date',to_char(n.created_at,'YYYY-MM-DD'),'files',(select count(*) from files f where f.note_id=n.id),
       'snippet',case when v_mode in('fulltext','fulltext_any') and n.fts @@ v_q
         then ts_headline('russian',n.body_md,v_q,'MaxWords=35, MinWords=12, MaxFragments=2') else left(n.body_md,240) end,
       'semantic_distance',c.distance) item,
      c.lexical,c.distance,n.created_at
    from notes n join lateral (select greatest(coalesce(ts_rank(n.fts,v_q),0),
      coalesce((select max(ts_rank(f.fts,v_q)) from files f where f.note_id=n.id),0)) lexical,
      (select min(e.embedding OPERATOR(extensions.<=>) p_query_embedding) from note_embeddings e where e.note_id=n.id and e.model=p_embedding_model) distance) c on true
    where (p_space is null or n.space=p_space) and (p_project is null or n.project=lower(p_project))
      and (p_since is null or n.created_at>=p_since) and (p_include_superseded or n.status='active')
      and ((v_mode='hybrid' and (c.distance is not null or (v_text is not null and
        (n.fts @@ v_q or exists(select 1 from files f where f.note_id=n.id and f.fts @@ v_q))))) or (v_mode in('fulltext','fulltext_any') and
        (n.fts @@ v_q or exists(select 1 from files f where f.note_id=n.id and f.fts @@ v_q)))
        or (v_mode='substring' and (n.title ilike '%'||v_text||'%' or n.body_md ilike '%'||v_text||'%'
          or exists(select 1 from files f where f.note_id=n.id and f.name ilike '%'||v_text||'%')))
        or v_mode='recent')
    order by case when v_mode='hybrid' then (coalesce(c.lexical,0)/(1+coalesce(c.lexical,0)))+(1/(1+coalesce(c.distance,1)))
      when v_mode in('fulltext','fulltext_any') then c.lexical else 0 end desc,n.created_at desc limit v_lim
  ) s;
  return jsonb_build_object('mode',v_mode,'total',v_total,'returned',jsonb_array_length(v_items),
    'truncated',v_total>jsonb_array_length(v_items),'items',v_items,
    'hint','memohub.get(id) returns the full note with its files');
end $$;

revoke execute on all functions in schema memohub from public;
