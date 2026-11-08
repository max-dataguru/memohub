-- Search and dedup eval (0.6) on tests/eval/cases.json, in a fresh database (tests/run-eval.sh).
-- Prints hit@1, hit@5 and MRR of memohub.search and every miss; fails below the thresholds, so a
-- change to search, ranking or the distiller cannot make known answers harder to find silently.
\set ON_ERROR_STOP on
select set_config('eval.cases', :'cases', false) \g /dev/null
select set_config('eval.min_hit5', :'min_hit5', false) \g /dev/null
select set_config('eval.min_mrr', :'min_mrr', false) \g /dev/null
select set_config('eval.max_dedup_fp', :'max_dedup_fp', false) \g /dev/null

create temp table eval_ids (key text primary key, id uuid);

do $$
declare
  c jsonb := current_setting('eval.cases')::jsonb;
  n jsonb; r jsonb;
begin
  for n in select jsonb_array_elements(c->'notes') loop
    r := memohub.save(jsonb_build_object('space', n->>'space', 'title', n->>'title', 'body_md', n->>'body_md',
           'tags', coalesce(n->'tags', '[]'), 'source', 'claude-code', 'new_topic', true));
    if not (r->>'ok')::boolean then raise exception 'eval note % not saved: %', n->>'key', r; end if;
    insert into eval_ids values (n->>'key', (r->>'id')::uuid);
  end loop;
end $$;

do $$
declare
  c jsonb := current_setting('eval.cases')::jsonb;
  q jsonb; r jsonb; rank int; n int := 0; h1 int := 0; h5 int := 0; rr numeric := 0;
  v_id uuid; mrr numeric; hit5 numeric;
begin
  for q in select jsonb_array_elements(c->'queries') loop
    select id into v_id from eval_ids where key = q->>'expect';
    r := memohub.search(q->>'q', p_limit => 10);
    select o into rank from jsonb_array_elements(r->'items') with ordinality as t(it, o)
     where (it->>'id')::uuid = v_id limit 1;
    n := n + 1;
    if rank = 1 then h1 := h1 + 1; end if;
    if rank <= 5 then h5 := h5 + 1; end if;
    if rank is not null then rr := rr + 1.0 / rank; end if;
    if rank is null or rank > 1 then
      raise notice 'miss  % → % (rank %, mode %)', q->>'q', q->>'expect', coalesce(rank::text, '-'), r->>'mode';
    end if;
  end loop;
  hit5 := round(h5::numeric / n, 3); mrr := round(rr / n, 3);
  raise notice 'search  queries %  hit@1 %  hit@5 %  MRR %', n, round(h1::numeric / n, 3), hit5, mrr;
  if hit5 < current_setting('eval.min_hit5')::numeric or mrr < current_setting('eval.min_mrr')::numeric then
    raise exception 'search eval below thresholds: hit@5 % (min %), MRR % (min %)',
      hit5, current_setting('eval.min_hit5'), mrr, current_setting('eval.min_mrr');
  end if;
end $$;

-- Multi-query search (multi_search): a question worded unlike the note plus short alternatives,
-- the way clients without embeddings are told to search. Must meet the same thresholds and must
-- not be worse than the question alone.
do $$
declare
  c jsonb := current_setting('eval.cases')::jsonb;
  q jsonb; r jsonb; v_id uuid; rank1 int; rankm int;
  n int := 0; h1 int := 0; h5 int := 0; rr numeric := 0; rr1 numeric := 0; mrr numeric; hit5 numeric;
begin
  for q in select jsonb_array_elements(c->'multi') loop
    select id into v_id from eval_ids where key = q->>'expect';
    r := memohub.search(q->>'q', p_limit => 10);
    select o into rank1 from jsonb_array_elements(r->'items') with ordinality as t(it, o)
     where (it->>'id')::uuid = v_id limit 1;
    r := memohub.multi_search(q->>'q', array(select jsonb_array_elements_text(q->'also')), p_limit => 10);
    select o into rankm from jsonb_array_elements(r->'items') with ordinality as t(it, o)
     where (it->>'id')::uuid = v_id limit 1;
    n := n + 1;
    if rankm = 1 then h1 := h1 + 1; end if;
    if rankm <= 5 then h5 := h5 + 1; end if;
    if rankm is not null then rr := rr + 1.0 / rankm; end if;
    if rank1 is not null then rr1 := rr1 + 1.0 / rank1; end if;
    if rankm is null or rankm > 1 then
      raise notice 'multi miss  % → % (rank %, alone %)', q->>'q', q->>'expect',
        coalesce(rankm::text, '-'), coalesce(rank1::text, '-');
    end if;
  end loop;
  hit5 := round(h5::numeric / n, 3); mrr := round(rr / n, 3);
  raise notice 'multi   queries %  hit@1 %  hit@5 %  MRR %  (question alone: MRR %)',
    n, round(h1::numeric / n, 3), hit5, mrr, round(rr1 / n, 3);
  if hit5 < current_setting('eval.min_hit5')::numeric or mrr < current_setting('eval.min_mrr')::numeric
     or mrr < round(rr1 / n, 3) then
    raise exception 'multi_search eval below thresholds: hit@5 % (min %), MRR % (min %, alone %)',
      hit5, current_setting('eval.min_hit5'), mrr, current_setting('eval.min_mrr'), round(rr1 / n, 3);
  end if;
end $$;

-- Dedup: a near-identical title must stop with similar_exists (a miss means a duplicate note);
-- a different topic should not (a false alarm only costs the user one question, so a few are
-- tolerated: EVAL_MAX_DEDUP_FP).
do $$
declare
  c jsonb := current_setting('eval.cases')::jsonb;
  s jsonb; r jsonb; got boolean; fn int := 0; fp int := 0;
begin
  for s in select jsonb_array_elements(c->'similar') loop
    r := memohub.save(jsonb_build_object('space', (select n->>'space' from jsonb_array_elements(c->'notes') n
                                                     where n->>'key' = s->>'existing'),
           'title', s->>'title', 'source', 'claude-code'));
    got := coalesce(r->>'error', '') = 'similar_exists';
    if (s->>'expect')::boolean and not got then
      fn := fn + 1;
      raise notice 'dedup MISSED (duplicate saved)  "%" vs %', s->>'title', s->>'existing';
    elsif got and not (s->>'expect')::boolean then
      fp := fp + 1;
      raise notice 'dedup false alarm  "%" vs %', s->>'title', s->>'existing';
    end if;
  end loop;
  raise notice 'dedup   cases %  missed %  false alarms %', jsonb_array_length(c->'similar'), fn, fp;
  if fn > 0 or fp > current_setting('eval.max_dedup_fp')::int then
    raise exception 'dedup eval: missed %, false alarms % (max %)', fn, fp, current_setting('eval.max_dedup_fp');
  end if;
end $$;

select 'EVAL OK' as result;
