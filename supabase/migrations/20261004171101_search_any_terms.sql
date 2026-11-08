-- Search fallback chain: all terms -> any term -> substring.
-- Models often pass a whole question ("почему не открываем NAS в интернет"); requiring
-- every word made such queries return nothing. Any-term matches are ranked by ts_rank,
-- so notes sharing more terms come first.

create or replace function brain.search(
  q                    text    default null,
  p_space              text    default null,
  p_project            text    default null,
  p_since              date    default null,
  p_limit              int     default 8,
  p_include_superseded boolean default false
)
returns jsonb
language plpgsql stable
set search_path = brain, pg_catalog
as $$
declare
  v_lim   int := least(greatest(coalesce(p_limit, 8), 1), 25);
  v_text  text := nullif(trim(q), '');
  v_q     tsquery;
  v_mode  text := 'recent';
  v_total int;
  v_items jsonb;
begin
  if v_text is not null then
    v_q := websearch_to_tsquery('russian', v_text);
    v_mode := 'fulltext';
  end if;

  select count(*) into v_total
    from notes n
   where (v_q is null or n.fts @@ v_q)
     and (p_space is null or n.space = p_space)
     and (p_project is null or n.project = lower(p_project))
     and (p_since is null or n.created_at >= p_since)
     and (p_include_superseded or n.status = 'active');

  -- Any term: OR over the stemmed lexemes of the query (stop words already dropped).
  if v_total = 0 and v_text is not null then
    select string_agg(quote_literal(lexeme), ' | ')::tsquery into v_q
      from unnest(tsvector_to_array(to_tsvector('russian', v_text))) as lexeme;
    if v_q is not null then
      v_mode := 'fulltext_any';
      select count(*) into v_total
        from notes n
       where n.fts @@ v_q
         and (p_space is null or n.space = p_space)
         and (p_project is null or n.project = lower(p_project))
         and (p_since is null or n.created_at >= p_since)
         and (p_include_superseded or n.status = 'active');
    end if;
  end if;

  -- Names, codes and partial words the stemmer misses: fall back to substring.
  if v_total = 0 and v_text is not null then
    v_mode := 'substring';
    select count(*) into v_total
      from notes n
     where (n.title ilike '%' || v_text || '%' or n.body_md ilike '%' || v_text || '%')
       and (p_space is null or n.space = p_space)
       and (p_project is null or n.project = lower(p_project))
       and (p_since is null or n.created_at >= p_since)
       and (p_include_superseded or n.status = 'active');
  end if;

  select coalesce(jsonb_agg(item order by ord), '[]'::jsonb) into v_items
  from (
    select row_number() over () as ord,
           jsonb_build_object(
             'id', n.id, 'space', n.space, 'project', n.project, 'type', n.type,
             'title', n.title, 'status', n.status, 'source', n.source,
             'date', to_char(n.created_at, 'YYYY-MM-DD'),
             'snippet', case
               when v_mode in ('fulltext', 'fulltext_any')
                 then ts_headline('russian', n.body_md, v_q,
                                  'MaxWords=35, MinWords=12, MaxFragments=2')
               else left(n.body_md, 240) end
           ) as item
      from notes n
     where (case
              when v_mode in ('fulltext', 'fulltext_any') then n.fts @@ v_q
              when v_mode = 'substring' then n.title ilike '%' || v_text || '%'
                                          or n.body_md ilike '%' || v_text || '%'
              else true end)
       and (p_space is null or n.space = p_space)
       and (p_project is null or n.project = lower(p_project))
       and (p_since is null or n.created_at >= p_since)
       and (p_include_superseded or n.status = 'active')
     order by case when v_mode in ('fulltext', 'fulltext_any')
                   then ts_rank(n.fts, v_q) else 0 end desc,
              n.created_at desc
     limit v_lim
  ) s;

  return jsonb_build_object(
    'mode', v_mode,
    'total', v_total,
    'returned', jsonb_array_length(v_items),
    'truncated', v_total > jsonb_array_length(v_items),
    'items', v_items,
    'hint', 'brain.get(id) returns the full note'
  );
end;
$$;

revoke execute on function brain.search(text, text, text, date, int, boolean) from public;
