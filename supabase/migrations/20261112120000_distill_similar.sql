-- The distiller checks a proposed note against notes already saved from other chats: active notes
-- in the same space whose title is similar (the same trigram test and threshold as save()).
-- Owner-only, like the rest of the distiller.
create function memohub._distill_similar(p_space text, p_title text)
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  select coalesce(jsonb_agg(c order by (c->>'similarity')::numeric desc), '[]') from (
    select jsonb_build_object('id', n.id, 'title', n.title, 'created_at', n.created_at,
                              'similarity', round(extensions.similarity(n.title, trim(p_title))::numeric, 2)) c
      from notes n
     where n.status = 'active' and n.space = p_space
       and extensions.similarity(n.title, trim(p_title)) >= _cfg_bigint('similar_pct', 45) / 100.0
     order by extensions.similarity(n.title, trim(p_title)) desc
     limit 3) s;
$$;
revoke execute on function memohub._distill_similar(text, text) from public;
