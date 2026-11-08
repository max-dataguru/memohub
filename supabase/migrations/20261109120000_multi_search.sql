-- Multi-query search for clients without a query embedding (Claude on the phone, claude.ai,
-- ChatGPT, a work computer): the client sends its question plus a few short reformulations, the
-- server searches each one and merges the lists. Live eval 07.11 on 19 real questions, blind
-- reformulations by another model: hit@5 0.58 -> 0.89, MRR 0.58 -> 0.77 (hybrid with local embeddings:
-- 1.00 / 0.89).
--
-- Design:
-- * A new name, not an overload of search(): PostgREST cannot pick between overloads with
--   defaults, and existing calls stay exactly as they were.
-- * Each query goes through search()'s own chain (all words -> any word -> substring), so one
--   vague alternative does not loosen the others or the original question.
-- * Lists are merged by reciprocal rank fusion (k = 60); ts_rank values of different queries are
--   not comparable. The original question weighs 1.5, each alternative 1.
-- * The server bounds the alternatives itself: at most 4, each at most 200 characters; empty ones,
--   repeats and copies of q are dropped (reported in "skipped").
-- * Each item says which queries found it (matched_queries: 0 = q, 1.. = p_also in order) and
--   carries the snippet from the query that ranked it highest.
--
-- Tags join the search vector (weight B, like decisions and entities): a note tagged "telemetry"
-- is now found by that word even if the body never uses it.

create function memohub._tags_text(p_tags text[])
returns text language sql immutable parallel safe
set search_path = pg_catalog as $$
  select coalesce(array_to_string(p_tags, ' '), '')
$$;
revoke execute on function memohub._tags_text(text[]) from public;

drop index memohub.notes_fts_idx;
alter table memohub.notes drop column fts;
alter table memohub.notes add column fts tsvector generated always as (
  setweight(to_tsvector('russian', title), 'A') ||
  setweight(to_tsvector('russian', decisions::text || ' ' || open_questions::text
                                   || ' ' || entities::text || ' ' || memohub._tags_text(tags)), 'B') ||
  setweight(to_tsvector('russian', body_md), 'C')
) stored;
create index notes_fts_idx on memohub.notes using gin (fts);

create function memohub.multi_search(
  q text default null, p_also text[] default null,
  p_space text default null, p_project text default null, p_since date default null,
  p_limit int default 8, p_include_superseded boolean default false)
returns jsonb language plpgsql stable
set search_path = memohub, pg_catalog as $$
declare
  v_lim     int := least(greatest(coalesce(p_limit, 8), 1), 25);
  v_q       text := nullif(trim(q), '');
  v_queries text[] := '{}';
  v_weights numeric[] := '{}';
  v_skipped jsonb := '[]';
  v_runs    jsonb := '[]';
  v_alt     text;
  v_r       jsonb;
  v_items   jsonb;
  v_found   int;
  v_trunc   boolean := false;
begin
  if v_q is not null then
    v_queries := array[v_q]; v_weights := array[1.5];
  end if;
  foreach v_alt in array coalesce(p_also, '{}') loop
    v_alt := nullif(trim(v_alt), '');
    if v_alt is null then
      continue;
    elsif length(v_alt) > 200 then
      v_skipped := v_skipped || jsonb_build_object('q', left(v_alt, 60), 'reason', 'too_long');
    elsif lower(v_alt) = any (select lower(x) from unnest(v_queries) x) then
      v_skipped := v_skipped || jsonb_build_object('q', v_alt, 'reason', 'duplicate');
    elsif cardinality(v_queries) - (v_q is not null)::int >= 4 then
      v_skipped := v_skipped || jsonb_build_object('q', v_alt, 'reason', 'too_many');
    else
      v_queries := v_queries || v_alt; v_weights := v_weights || 1.0;
    end if;
  end loop;

  -- Nothing to search by: same as search() without a query (recent notes).
  if cardinality(v_queries) = 0 then
    return memohub.search(null, p_space, p_project, p_since, v_lim, p_include_superseded)
           || jsonb_build_object('queries', '[]'::jsonb, 'skipped', v_skipped);
  end if;

  for i in 1 .. cardinality(v_queries) loop
    v_r := memohub.search(v_queries[i], p_space, p_project, p_since, 25, p_include_superseded);
    v_trunc := v_trunc or coalesce((v_r->>'truncated')::boolean, false);
    v_runs := v_runs || jsonb_build_object(
      'i', i - 1 + (v_q is null)::int, 'w', v_weights[i], 'q', v_queries[i],
      'mode', v_r->>'mode', 'total', (v_r->>'total')::int, 'items', v_r->'items');
  end loop;

  with hits as (
    select (r->>'i')::int as qi, (r->>'w')::numeric / (60 + t.o) as part, t.it
      from jsonb_array_elements(v_runs) r,
           jsonb_array_elements(r->'items') with ordinality as t(it, o)
  ), merged as (
    select it->>'id' as id, sum(part) as score,
           array_agg(distinct qi) as matched,
           (array_agg(it order by part desc, qi))[1] as best
      from hits group by it->>'id'
  )
  select count(*)::int,
         coalesce(jsonb_agg(item order by score desc, date desc) filter (where rn <= v_lim), '[]')
    into v_found, v_items
    from (select best || jsonb_build_object('matched_queries', to_jsonb(matched),
                                            'score', round(score, 4)) as item,
                 score, best->>'date' as date,
                 row_number() over (order by score desc, best->>'date' desc) as rn
            from merged) s;

  return jsonb_build_object(
    'mode', 'multi',
    'queries', (select jsonb_agg(jsonb_build_object('i', r->'i', 'q', r->'q', 'mode', r->'mode',
                                                    'total', r->'total') order by (r->>'i')::int)
                  from jsonb_array_elements(v_runs) r),
    'skipped', v_skipped,
    'total', v_found,
    'returned', jsonb_array_length(v_items),
    'truncated', v_trunc or v_found > jsonb_array_length(v_items),
    'items', v_items,
    'hint', 'memohub.get(id) returns the full note with its files'
  );
end $$;
revoke execute on function memohub.multi_search(text, text[], text, text, date, int, boolean) from public;

create function memohub_api.multi_search(
  q text default null, p_also text[] default null,
  p_space text default null, p_project text default null, p_since date default null,
  p_limit int default 8, p_include_superseded boolean default false)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin
  perform memohub._require_member();
  return memohub.multi_search(q, p_also, p_space, p_project, p_since, p_limit, p_include_superseded);
end $$;
revoke execute on function memohub_api.multi_search(text, text[], text, text, date, int, boolean) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function memohub_api.multi_search(text, text[], text, text, date, int, boolean)
      from anon, service_role;
  end if;
end $$;
grant execute on function memohub_api.multi_search(text, text[], text, text, date, int, boolean) to authenticated;
