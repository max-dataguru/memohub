-- Smoke test for the memohub schema (supabase/migrations/*) on a throwaway Postgres.
-- Every check raises on failure; a clean run prints "SMOKE OK".

\set ON_ERROR_STOP on

do $$
declare
  r jsonb;
  v_old uuid;
  v_new uuid;
  v_doc uuid;
begin
  -- Unknown space is rejected with the allowed list.
  r := memohub.save('{"space":"nope","title":"x","source":"manual"}');
  assert r->>'error' = 'unknown_space', r::text;
  assert jsonb_array_length(r->'allowed') = 5, r::text;

  -- Unknown project is not created silently.
  r := memohub.save('{"space":"work","project":"agent_platform","title":"x","source":"claude-code"}');
  assert r->>'error' = 'unknown_project', r::text;

  -- Repo-style slugs (underscore, mixed case) are accepted and lower-cased.
  r := memohub.add_project('Agent_Platform', 'work', 'Agent Platform', array['платформа']);
  assert (r->>'ok')::boolean and r->>'slug' = 'agent_platform', r::text;
  r := memohub.add_project('agent_platform', 'work', 'dup');
  assert r->>'error' = 'project_exists', r::text;

  -- Project from another space is rejected.
  r := memohub.save('{"space":"personal","project":"agent_platform","title":"x","source":"claude"}');
  assert r->>'error' = 'unknown_project', r::text;

  -- Save via alias, with quotes and code in the body.
  r := memohub.save($memo${
    "space": "work", "project": "Платформа", "type": "decision",
    "title": "Second brain живёт в Supabase",
    "body_md": "## Контекст\nВыбирали между Notion и Supabase. It's a test with 'quotes'.\n```sql\nselect 1;\n```",
    "decisions": ["Supabase как основная база, потому что сразу Postgres"],
    "open_questions": ["Когда переходить на свой MCP?"],
    "tags": ["Memory", "supabase"], "source": "claude"
  }$memo$);
  assert (r->>'ok')::boolean and r->>'project' = 'agent_platform', r::text;
  v_old := (r->>'id')::uuid;

  -- No project = inbox.
  r := memohub.save('{"space":"travel","title":"Идеи поездки в Грузию","body_md":"Тбилиси, Казбеги","source":"chatgpt"}');
  assert (r->>'inbox')::boolean, r::text;

  -- Full-text search: Russian noun inflection (основная база -> основной базы),
  -- English stemming (quotes -> quote).
  r := memohub.search('основной базы supabase');
  assert (r->>'total')::int = 1 and r->>'mode' = 'fulltext', r::text;
  r := memohub.search('quote', p_space => 'work');
  assert (r->>'total')::int = 1 and r->>'mode' = 'fulltext', r::text;
  r := memohub.search('Тбилиси', p_space => 'travel');
  assert (r->>'total')::int = 1, r::text;
  r := memohub.search('Тбилиси', p_space => 'work');
  assert (r->>'total')::int = 0, r::text;

  -- A whole question: not every word is in the note, any-term fallback finds it.
  r := memohub.search('почему мы выбрали основную базу Supabase?');
  assert r->>'mode' = 'fulltext_any' and (r->>'total')::int >= 1, r::text;
  assert r->'items'->0->>'title' = 'Second brain живёт в Supabase', r::text;
  -- Only stop words: nothing to search by, falls through to substring.
  r := memohub.search('и в на');
  assert r->>'mode' = 'substring', r::text;

  -- Substring fallback for partial words.
  r := memohub.search('Казбе');
  assert r->>'mode' = 'substring' and (r->>'total')::int = 1, r::text;

  -- Project filter is case-insensitive.
  r := memohub.search(null, p_project => 'AGENT_PLATFORM');
  assert (r->>'total')::int = 1, r::text;

  -- Supersede hides the old note from default search.
  r := memohub.save(format('{"space":"work","project":"agent_platform","type":"decision","title":"Свой MCP на Edge Function","source":"claude-code","supersedes":"%s"}', v_old)::jsonb);
  v_new := (r->>'id')::uuid;
  r := memohub.search(null, p_project => 'agent_platform');
  assert (r->>'total')::int = 1 and r->'items'->0->>'id' = v_new::text, r::text;
  r := memohub.search(null, p_project => 'agent_platform', p_include_superseded => true);
  assert (r->>'total')::int = 2, r::text;

  -- Limit is capped and truncation is flagged.
  for i in 1..30 loop
    perform memohub.save(format('{"space":"learning","title":"Заметка %s","source":"manual","new_topic":true}', i)::jsonb);
  end loop;
  r := memohub.search(null, p_space => 'learning', p_limit => 100);
  assert (r->>'returned')::int = 25 and (r->>'truncated')::boolean, r::text;

  -- Entities: validated, trimmed, de-duplicated; names are searchable.
  r := memohub.save('{"space":"work","title":"x","source":"manual","entities":[{"type":"planet","name":"Mars"}]}');
  assert r->>'error' = 'bad_entities', r::text;
  r := memohub.save($memo${"space":"travel","title":"План поездки","source":"claude",
    "tags":["Georgia"," georgia ","горы"],
    "entities":[{"type":"place","name":" Тбилиси "},{"type":"place","name":"тбилиси"},
                {"type":"tool","name":"Booking"}]}$memo$);
  assert (r->>'ok')::boolean, r::text;
  r := memohub.get((r->>'id')::uuid);
  assert jsonb_array_length(r->'entities') = 2, r::text;
  assert r->'tags' = '["georgia", "горы"]'::jsonb, r::text;
  r := memohub.search('booking');
  assert (r->>'total')::int = 1 and r->>'mode' = 'fulltext', r::text;
  -- Tags are in the search vector: "georgia" is only a tag of that note.
  r := memohub.search('georgia');
  assert (r->>'total')::int = 1 and r->>'mode' = 'fulltext'
         and r->'items'->0->>'title' = 'План поездки', r::text;

  -- Multi-query search: each query runs search()'s own chain, lists merge by RRF; the server
  -- drops empty, repeated, too long and extra alternatives and says why.
  r := memohub.multi_search('основной базы',
         array['Notion', 'notion', ' ', 'Казбеги', 'горы', 'booking', repeat('z', 201), 'лишняя'],
         p_include_superseded => true);  -- the Supabase note was superseded above
  assert r->>'mode' = 'multi', r::text;
  assert jsonb_array_length(r->'queries') = 5, r::text;
  assert (select array_agg(s->>'reason' order by s->>'reason') from jsonb_array_elements(r->'skipped') s)
         = array['duplicate', 'too_long', 'too_many'], r::text;
  assert r->'items'->0->>'title' = 'Second brain живёт в Supabase', r::text;
  assert r->'items'->0->'matched_queries' = '[0, 1]'::jsonb, r::text;
  assert exists (select 1 from jsonb_array_elements(r->'items') it
                  where it->>'title' = 'Идеи поездки в Грузию' and it->'matched_queries' = '[2]'::jsonb), r::text;
  assert exists (select 1 from jsonb_array_elements(r->'items') it
                  where it->>'title' = 'План поездки' and it->'matched_queries' = '[3, 4]'::jsonb), r::text;
  -- Alternatives only (no q): numbering still starts at 1 for p_also.
  r := memohub.multi_search(null, array['Казбеги']);
  assert r->'queries'->0->>'i' = '1' and r->'items'->0->'matched_queries' = '[1]'::jsonb, r::text;
  -- Nothing to search by: recent notes, like search(null).
  r := memohub.multi_search(null, array['', null]);
  assert r->>'mode' = 'recent' and r->'queries' = '[]'::jsonb, r::text;
  r := memohub.multi_search('поездки', p_limit => 1);
  assert (r->>'returned')::int = 1, r::text;

  -- Catalog lists tags and entities by use.
  r := memohub.catalog();
  assert r->'tags'->0->>'tag' is not null, r::text;
  assert exists (select 1 from jsonb_array_elements(r->'entities') e
                  where e->>'name' = 'Тбилиси' and e->>'type' = 'place'), r::text;
  assert jsonb_array_length(r->'entity_types') = 5, r::text;

  -- Sensitive data is rejected; kinds are reported, values are not echoed.
  r := memohub.save($memo${"space":"personal","title":"Оплата","source":"claude","body_md":"карта 4111 1111 1111 1111"}$memo$);
  assert r->>'error' = 'sensitive_data' and r->'kinds' ? 'card_number', r::text;
  assert position('4111' in r::text) = 0, r::text;
  r := memohub.save($memo${"space":"personal","title":"Счёт","source":"claude","body_md":"IBAN DE89 3704 0044 0532 0130 00"}$memo$);
  assert r->'kinds' ? 'iban', r::text;
  r := memohub.save($memo${"space":"personal","title":"Документы","source":"claude","body_md":"Паспорт: 45 12 345678"}$memo$);
  assert r->'kinds' ? 'passport_number', r::text;
  r := memohub.save($memo${"space":"personal","title":"СНИЛС","source":"claude","body_md":"112-233-445 95"}$memo$);
  assert r->'kinds' ? 'snils', r::text;
  r := memohub.save($memo${"space":"work","title":"DB","source":"claude","body_md":"postgres://app:s3cret@db.example.com/x"}$memo$);
  assert r->'kinds' ? 'credential', r::text;
  r := memohub.save($memo${"space":"work","title":"Keys","source":"claude","decisions":["пароль: hunter22"]}$memo$);
  assert r->'kinds' ? 'credential', r::text;
  -- Ordinary numbers pass: dates, phone, non-Luhn order id, version strings.
  r := memohub.save($memo${"space":"personal","title":"Заказ","source":"claude",
    "body_md":"2026-10-04, тел +7 999 123-45-67, заказ 1234 5678 9012 3456, Postgres 17.6.1.166, 364 ГБ"}$memo$);
  assert (r->>'ok')::boolean, r::text;

  -- Private spaces: rejected in the shared tier, accepted in the private one.
  r := memohub.save('{"space":"medicine","title":"Анализы","source":"claude"}');
  assert r->>'error' = 'private_space', r::text;
  assert memohub.catalog()->>'tier' = 'shared';
  insert into memohub.config values ('tier', 'private');
  r := memohub.save('{"space":"medicine","title":"Анализы","source":"claude"}');
  assert (r->>'ok')::boolean and r->>'tier' = 'private', r::text;
  delete from memohub.config where key = 'tier';

  -- Files: quota check before upload, attach after, search through file contents.
  assert (select public from storage.buckets where id = 'files') = false;
  r := memohub.check_upload(60000000);
  assert r->>'error' = 'file_too_large', r::text;
  r := memohub.check_upload(1000000);
  assert (r->>'ok')::boolean and not (r->>'warn')::boolean, r::text;
  r := memohub.save('{"space":"personal","title":"Договор аренды квартиры","source":"claude-code","body_md":"Подписали договор"}');
  v_doc := (r->>'id')::uuid;
  r := memohub.attach_file(jsonb_build_object('note_id', v_doc, 'path', '2026/10/lease.pdf'));
  assert r->>'error' = 'object_not_found', r::text;
  insert into storage.objects (bucket_id, name, metadata)
    values ('files', '2026/10/lease.pdf', '{"size": 1500000, "mimetype": "application/pdf"}');
  r := memohub.attach_file(jsonb_build_object('note_id', v_doc, 'path', '2026/10/lease.pdf',
         'summary', 'Договор аренды на 12 месяцев', 'sha256', 'ABC123',
         'extracted_text', 'Арендодатель обязуется передать помещение. Залог возвращается через 30 дней.'));
  assert (r->>'ok')::boolean and r->>'name' = 'lease.pdf', r::text;
  assert (r->'usage'->>'used_bytes')::bigint = 1500000, r::text;

  -- Duplicate by sha256 is reported instead of a second upload.
  r := memohub.check_upload(1500000, 'abc123');
  assert r->'duplicate'->>'name' = 'lease.pdf', r::text;

  -- Near the limit: warning; over it: refusal.
  insert into memohub.config values ('storage_limit_bytes', '2000000');
  r := memohub.check_upload(200000);
  assert (r->>'ok')::boolean and (r->>'warn')::boolean and r->>'message' like '%85%', r::text;
  r := memohub.check_upload(600000);
  assert r->>'error' = 'quota_exceeded', r::text;
  delete from memohub.config where key = 'storage_limit_bytes';

  -- Search finds the note by words that exist only inside the file.
  r := memohub.search('залог');
  assert (r->>'total')::int = 1 and r->'items'->0->>'snippet' like 'файл «lease.pdf»%', r::text;
  r := memohub.get(v_doc);
  assert jsonb_array_length(r->'files') = 1 and (r->'files'->0->>'has_text')::boolean, r::text;
  r := memohub.get_file((select id from memohub.files where name = 'lease.pdf'));
  assert r->>'text' like 'Арендодатель%' and not (r->>'text_truncated')::boolean, r::text;

  -- Company document: link only; sensitive text in a file is refused.
  r := memohub.attach_file(jsonb_build_object('note_id', v_doc, 'url', 'https://docs.example.com/d/1', 'name', 'Регламент'));
  assert (r->>'ok')::boolean, r::text;
  r := memohub.attach_file(jsonb_build_object('note_id', v_doc, 'url', 'https://example.com/x',
         'extracted_text', 'Паспорт 45 12 345678'));
  assert r->>'error' = 'sensitive_data', r::text;
  r := memohub.catalog();
  assert r->'storage'->>'files' = '1' and r ? 'files_hint', r::text;

  -- Guide: missing until synced, then returned with its version; catalog shows the version.
  r := memohub.guide();
  assert r->>'error' = 'guide_missing', r::text;
  insert into memohub.guides (key, sha256, body) values ('main', 'abcdef0123456789', '# memohub — инструкция');
  r := memohub.guide();
  assert r->>'version' = '1' and r->>'text' like '# memohub%' and r->>'sha256' = 'abcdef012345', r::text;
  assert memohub.catalog()->'guide'->>'version' = '1';

  -- Near-duplicate titles: refused with candidates; amend via supersedes or force new_topic.
  r := memohub.save('{"space":"learning","title":"Курс по статистике: план обучения","source":"claude"}');
  assert (r->>'ok')::boolean, r::text;
  v_doc := (r->>'id')::uuid;
  r := memohub.save('{"space":"learning","title":"Курс по статистике: план обучения и прогресс","source":"claude"}');
  assert r->>'error' = 'similar_exists' and r->'candidates'->0->>'id' = v_doc::text, r::text;
  r := memohub.save(jsonb_build_object('space','learning','title','Курс по статистике: план обучения и прогресс',
         'source','claude','supersedes', v_doc));
  assert (r->>'ok')::boolean, r::text;
  r := memohub.history((r->>'id')::uuid);
  assert jsonb_array_length(r) = 2 and r->0->>'status' = 'superseded' and r->1->>'status' = 'active', r::text;
  r := memohub.save('{"space":"learning","title":"Курс по статистике: план обучения и прогресс","source":"claude","new_topic":true}');
  assert (r->>'ok')::boolean, r::text;
  r := memohub.save('{"space":"learning","title":"Английский: словарь для собеседований","source":"claude"}');
  assert (r->>'ok')::boolean, r::text;

  -- Same chat, different title: refused as same_chat; amend works; another topic needs new_topic.
  r := memohub.save('{"space":"travel","title":"Поездка в Японию: бюджет","source":"chatgpt","chat_ref":"gpt-20261005-k7f2"}');
  assert (r->>'ok')::boolean and r->>'chat_ref' = 'gpt-20261005-k7f2', r::text;
  v_doc := (r->>'id')::uuid;
  r := memohub.save('{"space":"travel","title":"Токио — отели и JR Pass","source":"chatgpt","chat_ref":"gpt-20261005-k7f2"}');
  assert r->>'error' = 'same_chat' and r->'candidates'->0->>'id' = v_doc::text, r::text;
  r := memohub.save(jsonb_build_object('space','travel','title','Поездка в Японию: бюджет, отели, JR Pass',
         'source','chatgpt','chat_ref','gpt-20261005-k7f2','supersedes', v_doc));
  assert (r->>'ok')::boolean, r::text;
  r := memohub.save('{"space":"travel","title":"Виза в Китай","source":"chatgpt","chat_ref":"gpt-20261005-k7f2","new_topic":true}');
  assert (r->>'ok')::boolean, r::text;
  r := memohub.by_chat('gpt-20261005-k7f2');
  assert jsonb_array_length(r) = 2, r::text;
  assert jsonb_array_length(memohub.by_chat('gpt-20261005-k7f2', true)) = 3;
  -- Another chat on a different topic is not affected.
  r := memohub.save('{"space":"travel","title":"Кипр: аренда машины","source":"claude","chat_ref":"other-chat"}');
  assert (r->>'ok')::boolean, r::text;

  -- Graph: entities become nodes, relations become typed edges; graph() lists both.
  r := memohub.save($memo${"space":"work","title":"Созвон с поставщиком аналитики","source":"claude",
    "body_md":"Созвон с поставщиком аналитики Acme, обсудили продление договора","new_topic":true,"entities":[{"type":"person","name":"Анна"},{"type":"org","name":"Acme"}],
    "relations":[{"from":{"type":"person","name":"Анна"},"type":"works_at","to":{"type":"org","name":"Acme"}}]}$memo$);
  assert (r->>'ok')::boolean and (r->>'relations_created')::int = 1, r::text;
  v_doc := (r->>'id')::uuid;
  r := memohub.graph('person', 'анна');
  assert r->'entity'->>'name' = 'Анна', r::text;
  assert exists (select 1 from jsonb_array_elements(r->'edges') e where e->>'relation' = 'works_at' and e->>'name' = 'Acme'), r::text;
  assert exists (select 1 from jsonb_array_elements(r->'edges') e where e->>'relation' = 'mentions'), r::text;
  r := memohub.save('{"space":"work","title":"x","source":"claude","new_topic":true,"relations":[{"from":{"type":"planet","name":"Mars"},"type":"orbits","to":{"type":"org","name":"Acme"}}]}');
  assert r->>'error' = 'bad_relations', r::text;

  -- Embeddings: one dimension per model; hybrid search ranks by vector distance.
  r := memohub.put_embedding(v_doc, 'test-3d', '[1,0,0]');
  assert (r->>'ok')::boolean and (r->>'dimensions')::int = 3, r::text;
  r := memohub.put_embedding((select id from memohub.notes where title = 'Английский: словарь для собеседований'), 'test-3d', '[0,1,0]');
  assert (r->>'ok')::boolean, r::text;
  r := memohub.put_embedding(v_doc, 'test-3d', '[1,0]');
  assert r->>'error' = 'embedding_dimensions_mismatch', r::text;
  r := memohub.search(null, null, null, null, 5, false, '[0.9,0.1,0]', 'test-3d');
  assert r->>'mode' = 'hybrid' and r->'items'->0->>'id' = v_doc::text, r::text;
  r := memohub.search(null, null, null, null, 5, false, '[0.9,0.1,0]', null);
  assert r->>'error' = 'embedding_model_required', r::text;

  -- Contradiction candidates do not block: the note is saved and candidates come back.
  r := memohub.save($memo${"space":"work","title":"Поставщик аналитики: решение по договору","source":"claude",
    "body_md":"Созвон с поставщиком аналитики Acme, решили продлить договор","new_topic":true,
    "entities":[{"type":"org","name":"Acme"}]}$memo$);
  assert (r->>'ok')::boolean, r::text;
  assert exists (select 1 from jsonb_array_elements(r->'possible_contradictions') c where c->>'id' = v_doc::text), r::text;
  r := memohub.save($memo${"space":"work","title":"Acme: итог","source":"claude","new_topic":true,"conflicts_reviewed":true,
    "body_md":"Созвон с поставщиком аналитики Acme","entities":[{"type":"org","name":"Acme"}]}$memo$);
  assert (r->>'ok')::boolean and not r ? 'possible_contradictions', r::text;

  -- get / recent / catalog.
  r := memohub.get(v_new);
  assert r->>'title' = 'Свой MCP на Edge Function' and not r ? 'fts', r::text;
  r := memohub.get(gen_random_uuid());
  assert r->>'error' = 'not_found', r::text;
  r := memohub.recent('travel');
  assert (r->>'total')::int = 5, r::text;
  r := memohub.catalog();
  assert jsonb_array_length(r->'spaces') = 5, r::text;

  -- forget(): preview first, then the whole version chain, its file, embedding and own entities go;
  -- a tombstone stays and blocks re-insertion; shared entities survive.
  r := memohub.save($memo${"space":"personal","title":"Долг Борису Гречкину","source":"claude","new_topic":true,
    "body_md":"Вернуть Гречкину до весны","entities":[{"type":"person","name":"Борис Гречкин"},{"type":"org","name":"Acme"}],
    "relations":[{"from":{"type":"person","name":"Борис Гречкин"},"type":"works_at","to":{"type":"org","name":"Acme"}}]}$memo$);
  v_old := (r->>'id')::uuid;
  insert into storage.objects (bucket_id, name, metadata, created_at)
    values ('files', '2026/11/debt.pdf', '{"size": 1000}', now() - interval '2 days');
  r := memohub.attach_file(jsonb_build_object('note_id', v_old, 'path', '2026/11/debt.pdf', 'extracted_text', 'расписка Гречкина'));
  assert (r->>'ok')::boolean, r::text;
  perform memohub.put_embedding(v_old, 'test-3d', '[0,0,1]');
  r := memohub.save(jsonb_build_object('space','personal','title','Долг Борису Гречкину: график','source','claude',
         'body_md','Гречкину — частями','supersedes', v_old));
  v_new := (r->>'id')::uuid;
  r := memohub.save(jsonb_build_object('space','personal','title','Долг Борису Гречкину: график и остаток','source','claude',
         'body_md','Гречкину — остаток','supersedes', v_new));
  v_doc := (r->>'id')::uuid;

  -- Called on the middle version: the chain is followed both ways.
  r := memohub.forget(v_new);
  assert r->>'error' = 'confirm_required' and jsonb_array_length(r->'notes') = 3
     and jsonb_array_length(r->'files') = 1, r::text;
  assert exists (select 1 from memohub.notes where id = v_new);
  r := memohub.forget(v_new, true);
  assert (r->>'ok')::boolean and jsonb_array_length(r->'forgotten') = 3
     and r->'storage_paths' = '["2026/11/debt.pdf"]'::jsonb, r::text;
  assert not exists (select 1 from memohub.notes where id in (v_old, v_new, v_doc));
  assert (select count(*) from memohub.forgotten where id in (v_old, v_new, v_doc)) = 3;
  assert not exists (select 1 from memohub.files where path = '2026/11/debt.pdf');
  assert not exists (select 1 from memohub.note_embeddings where note_id = v_old);
  assert not exists (select 1 from memohub.entities where name = 'Борис Гречкин');
  assert exists (select 1 from memohub.entities where name = 'Acme');
  r := memohub.search('Гречкин', p_include_superseded => true);
  assert (r->>'total')::int = 0, r::text;
  assert memohub.get(v_new)->>'error' = 'not_found';
  assert memohub.forget(v_new)->>'already_forgotten' = 'true';
  assert memohub.forget(gen_random_uuid())->>'error' = 'not_found';
  -- Restoring an old backup cannot bring it back: the insert is skipped.
  insert into memohub.notes (id, space, title, source) values (v_old, 'personal', 'Долг Борису Гречкину', 'claude');
  assert not exists (select 1 from memohub.notes where id = v_old);
  -- The file object is now an orphan; fresh uploads are not listed yet.
  insert into storage.objects (bucket_id, name, metadata) values ('files', '2026/11/fresh.pdf', '{"size": 10}');
  r := memohub.orphan_objects();
  assert r @> '[{"path":"2026/11/debt.pdf"}]' and not r @> '[{"path":"2026/11/fresh.pdf"}]', r::text;
  assert not r @> '[{"path":"2026/10/lease.pdf"}]', r::text;
end $$;

-- Client API (0.4): Supabase Auth users listed in memohub.members, allowlisted wrappers only.
insert into memohub.members (user_id, label) values ('00000000-0000-0000-0000-00000000a11c', 'smoke');

do $$
declare
  v_expected text[] := array['add_project','approve_candidate','attach_file','by_chat','candidates','capture_thought',
    'catalog','check_upload','get','get_file','graph','guide','history','hybrid_search','is_member',
    'mark_candidate_exported','multi_search','put_embedding','recent','reject_candidate','save','search'];
begin
  -- The API is exactly the allowlist; forget and housekeeping are not in it.
  assert (select array_agg(p.proname::text order by p.proname) from pg_proc p
          where p.pronamespace = 'memohub_api'::regnamespace) = v_expected;
  -- PUBLIC gets nothing; anon only capture_thought (needs a device key); authenticated only the API.
  assert not exists (select 1 from pg_proc p where p.pronamespace in ('memohub'::regnamespace, 'memohub_api'::regnamespace)
                     and has_function_privilege('public', p.oid, 'execute'));
  assert (select array_agg(p.proname::text) from pg_proc p
          where p.pronamespace in ('memohub'::regnamespace, 'memohub_api'::regnamespace)
            and has_function_privilege('anon', p.oid, 'execute')) = array['capture_thought'];
  assert not exists (select 1 from pg_proc p where p.pronamespace = 'memohub'::regnamespace
                     and has_function_privilege('authenticated', p.oid, 'execute'));
  assert not exists (select 1 from pg_proc p where p.pronamespace = 'memohub_api'::regnamespace
                     and not has_function_privilege('authenticated', p.oid, 'execute'));
  assert not has_schema_privilege('authenticated', 'memohub', 'usage');
  assert not exists (select 1 from pg_class c where c.relnamespace = 'memohub'::regnamespace and c.relkind in ('r','v','m')
                     and (has_table_privilege('authenticated', c.oid, 'select,insert,update,delete')
                          or has_table_privilege('anon', c.oid, 'select,insert,update,delete')));
  -- Every API function is SECURITY DEFINER with a pinned search_path.
  assert not exists (select 1 from pg_proc p where p.pronamespace = 'memohub_api'::regnamespace
                     and (not p.prosecdef or p.proconfig is null));
end $$;

-- Not a member: refused.
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000ff","role":"authenticated"}', false);
do $$
begin
  begin perform memohub_api.catalog(); raise exception 'non-member got catalog';
  exception when insufficient_privilege then null; end;
  begin perform memohub_api.save('{"space":"personal","title":"x","source":"claude"}'); raise exception 'non-member saved';
  exception when insufficient_privilege then null; end;
  assert not memohub_api.is_member();
end $$;

-- No token at all: refused.
select set_config('request.jwt.claims', '', false);
do $$
begin
  begin perform memohub_api.search('Supabase'); raise exception 'anonymous search';
  exception when insufficient_privilege then null; end;
  begin perform memohub_api.multi_search('Supabase', array['Notion']); raise exception 'anonymous multi_search';
  exception when insufficient_privilege then null; end;
end $$;

-- Member: the allowlist works, the schema behind it does not.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated"}', false);
do $$
declare
  r jsonb;
  v_id uuid;
begin
  assert memohub_api.is_member();
  assert memohub_api.catalog() ? 'spaces';
  assert memohub_api.guide() is not null;
  r := memohub_api.save('{"space":"personal","title":"Записано через RPC API","body_md":"проверка клиента","source":"claude"}');
  assert (r->>'ok')::boolean, r::text;
  v_id := (r->>'id')::uuid;
  assert memohub_api.get(v_id)->>'title' = 'Записано через RPC API';
  assert (memohub_api.search('RPC')->>'total')::int >= 1;
  assert (memohub_api.multi_search('нет-такого-слова', array['RPC'])->>'total')::int >= 1;
  assert memohub_api.history(v_id) is not null;
  r := memohub_api.put_embedding(v_id, 'test-3d', '[1,0,0]');
  assert (r->>'ok')::boolean, r::text;
  r := memohub_api.hybrid_search('RPC', '[1,0,0]', 'test-3d');
  assert (r->>'total')::int >= 1, r::text;
  assert memohub_api.recent('personal') is not null;
  assert memohub_api.check_upload(10) ? 'ok';
  begin perform memohub.save('{"space":"personal","title":"x","source":"claude"}'); raise exception 'member reached memohub.save';
  exception when insufficient_privilege then null; end;
  begin perform memohub.forget(v_id); raise exception 'member reached forget';
  exception when insufficient_privilege then null; end;
  begin perform count(*) from memohub.notes; raise exception 'member read notes';
  exception when insufficient_privilege then null; end;
end $$;

-- anon reaches only capture_thought.
reset role;
set role anon;
do $$
begin
  begin perform memohub_api.catalog(); raise exception 'anon got catalog';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- Storage policies (0.4): members upload to and read bucket `files`; nothing else.
insert into storage.buckets (id, name, public) values ('other', 'other', false) on conflict do nothing;
insert into storage.objects (bucket_id, name, metadata) values ('other', 'secret.txt', '{"size": 1}');
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000ff","role":"authenticated"}', false);
do $$
begin
  begin insert into storage.objects (bucket_id, name) values ('files', 'rpc/nonmember.pdf'); raise exception 'non-member uploaded';
  exception when insufficient_privilege then null; end;
  assert not exists (select 1 from storage.objects), 'non-member sees objects';
end $$;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated"}', false);
do $$
declare n int;
begin
  insert into storage.objects (bucket_id, name, metadata) values ('files', 'rpc/member.pdf', '{"size": 3}');
  assert exists (select 1 from storage.objects where name = 'rpc/member.pdf');
  assert exists (select 1 from storage.objects where name = '2026/10/lease.pdf'), 'member cannot read files';
  assert not exists (select 1 from storage.objects where bucket_id <> 'files'), 'member reads other buckets';
  begin insert into storage.objects (bucket_id, name) values ('other', 'x.txt'); raise exception 'member wrote other bucket';
  exception when insufficient_privilege then null; end;
  update storage.objects set metadata = '{}' where name = 'rpc/member.pdf';
  get diagnostics n = row_count; assert n = 0, 'member updated an object';
  delete from storage.objects where name = 'rpc/member.pdf';
  get diagnostics n = row_count; assert n = 0, 'member deleted an object';
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
do $$
begin
  assert exists (select 1 from storage.objects where name = 'rpc/member.pdf');
  assert (select metadata from storage.objects where name = 'rpc/member.pdf') = '{"size": 3}';
end $$;

-- Capture journal (A1).
select set_config('memohub.mask_cases', :'mask_cases', false);
do $$
declare
  c jsonb;
  r jsonb;
  k text;
begin
  -- Masking matches tests/mask_cases.json (the scanner uses the same file).
  for c in select jsonb_array_elements(current_setting('memohub.mask_cases')::jsonb) loop
    r := memohub._mask_sensitive(c->>'in');
    assert r->>'text' = c->>'out', format('%s: %s', c->>'name', r->>'text');
    assert r->'kinds' = c->'kinds', format('%s kinds: %s', c->>'name', r->'kinds');
    -- Masked text is not a secret any more: save() accepts a note quoting the journal.
    assert memohub.sensitive_findings(r->>'text') = '{}', format('%s masked still flagged: %s', c->>'name',
      memohub.sensitive_findings(r->>'text'));
  end loop;

  -- A batch: inserted, masked, acked; source status recorded.
  r := memohub.capture_batch($j${"device": "home-mac",
    "items": [
      {"source": "claude-code", "chat_ref": "cc-1111", "project_hint": "memohub", "role": "user",
       "event_at": "2026-11-08T10:00:00Z", "seq": 1, "key": "cc-1111:m1", "content": "Обсуждаем журнал захвата, ключ sk-abcdefghijklmnopqrstuvwxyz1234"},
      {"source": "claude-code", "chat_ref": "cc-1111", "role": "assistant",
       "event_at": "2026-11-08T10:00:05Z", "seq": 2, "key": "cc-1111:m2", "content": "Журнал пишет реплики в captures"},
      {"source": "codex", "chat_ref": "codex-2222", "role": "user",
       "event_at": "2026-11-08T11:00:00Z", "key": "codex-2222:m1", "content": "Ревью миграции журнала"},
      {"source": "nope", "chat_ref": "x", "role": "user", "key": "bad:1", "content": "x"}
    ],
    "sources": [{"source": "claude-code", "cursor": {"files": 1}}, {"source": "codex"}]}$j$);
  assert (r->>'ok')::boolean and (r->>'inserted')::int = 3 and (r->>'masked')::int = 1, r::text;
  assert jsonb_array_length(r->'acked') = 3 and jsonb_array_length(r->'rejected') = 1, r::text;
  assert (select content from memohub.captures where idempotency_key = 'cc-1111:m1')
         = 'Обсуждаем журнал захвата, ключ [masked:credential]';
  assert (select (x->>'captures')::int from jsonb_array_elements(memohub.capture_status()->'sources') x
           where x->>'source' = 'claude-code') = 2;

  -- Re-sending is a no-op but still acked (the client may drop its spool).
  r := memohub.capture_batch('{"device": "home-mac", "items": [{"source": "codex", "chat_ref": "codex-2222",
        "role": "user", "event_at": "2026-11-08T11:00:00Z", "key": "codex-2222:m1", "content": "Ревью миграции журнала"}]}');
  assert (r->>'inserted')::int = 0 and (r->>'duplicates')::int = 1 and r->'acked' = '["codex-2222:m1"]', r::text;
  assert (select count(*) from memohub.captures) = 3;

  -- Search: Russian morphology and English words; notes search does not see the journal.
  r := memohub.search_captures('журналы');   -- plural finds the singular
  assert (r->>'total')::int >= 2, r::text;
  r := memohub.search_captures('ревью');
  assert (r->>'total')::int = 1 and r->'items'->0->>'chat_ref' = 'codex-2222', r::text;
  r := memohub.search_captures('captures', p_source => 'claude-code');
  assert (r->>'total')::int = 1, r::text;
  assert (memohub.search('Ревью миграции журнала')->>'total')::int = 0;
  r := memohub.captures_by_chat('cc-1111');
  assert (r->>'total')::int = 2 and r->'items'->0->>'role' = 'user', r::text;

  -- #nomemo: suppression goes first in the batch and removes what was already captured.
  r := memohub.capture_batch('{"device": "home-mac", "suppress": ["cc-1111"], "items": [
        {"source": "claude-code", "chat_ref": "cc-1111", "role": "user", "key": "cc-1111:m3", "content": "#nomemo личное"}]}');
  assert (r->>'suppressed')::int = 1 and (r->>'inserted')::int = 0 and r->'acked' = '["cc-1111:m3"]', r::text;
  assert r->'suppressed_chats' = '["cc-1111"]', r::text;
  assert not exists (select 1 from memohub.captures where chat_ref = 'cc-1111');

  -- forget_chat: preview, then delete; a restored old row is skipped by the trigger.
  r := memohub.forget_chat('codex-2222');
  assert r->>'error' = 'confirm_required' and (r->>'captures')::int = 1, r::text;
  r := memohub.forget_chat('codex-2222', true);
  assert (r->>'ok')::boolean and (r->>'captures_deleted')::int = 1, r::text;
  insert into memohub.captures (source, device, chat_ref, role, event_at, idempotency_key, content, content_sha256)
  values ('codex', 'home-mac', 'codex-2222', 'user', now(), 'codex-2222:m1', 'old backup', 'x');
  assert not exists (select 1 from memohub.captures where chat_ref = 'codex-2222');
  assert memohub.forget_chat('codex-2222')->>'already_forgotten' = 'true';
  assert (select reason from memohub.suppressed_chats where chat_ref = 'codex-2222') = 'forgotten';
  -- A later #nomemo does not downgrade a forgotten chat.
  perform memohub.suppress_chat('codex-2222', 'nomemo');
  assert (select reason from memohub.suppressed_chats where chat_ref = 'codex-2222') = 'forgotten';

  -- Limits.
  r := memohub.capture_batch(jsonb_build_object('device', 'home-mac', 'items', jsonb_build_array(
         jsonb_build_object('source', 'meeting', 'chat_ref', 'meeting-x', 'role', 'transcript',
                            'key', 'meeting-x:0', 'content', repeat('а', 60001)))));
  assert r->'rejected'->0->>'error' = 'content_too_long' and jsonb_array_length(r->'acked') = 0, r::text;
  assert memohub.capture_batch('{"items": []}')->>'error' = 'missing_device';

  r := memohub.capture_status();
  assert (r->>'captures')::int = 0 and (r->>'suppressed')::int = 2 and jsonb_array_length(r->'sources') = 2, r::text;

  -- Not reachable from the client API.
  assert not exists (select 1 from pg_proc p where p.pronamespace in ('memohub'::regnamespace, 'memohub_api'::regnamespace)
                     and p.proname in ('capture_batch', 'search_captures', 'forget_chat')
                     and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute')));
end $$;

-- Leave a capture for the backup roundtrip.
select memohub.capture_batch('{"device": "home-mac", "items": [{"source": "meeting", "chat_ref": "meeting-2026-11-08_10-00",
  "role": "transcript", "event_at": "2026-11-08T10:00:00Z", "key": "meeting-2026-11-08_10-00:0", "content": "Встреча про журнал"}]}') is not null as kept;

-- A2: thoughts from a device key (iPhone Shortcut), anon-callable.
select set_config('memohub.test_key', 'mh_' || md5('smoke-device-key') || md5('second half'), false);
select memohub.device_key_create('iphone', encode(sha256(convert_to(current_setting('memohub.test_key'), 'UTF8')), 'hex')) is not null as key_made;
do $$
declare r jsonb; k2 text;
begin
  assert memohub.device_key_create('Bad Name', repeat('a', 64))->>'error' = 'bad_device';
  assert memohub.device_key_create('ipad', 'not-a-hash')->>'error' = 'bad_hash';
  assert (select count(*) from memohub.device_keys where revoked_at is null and device = 'iphone') = 1;
  assert not exists (select 1 from memohub.device_keys where key_hash = current_setting('memohub.test_key')), 'plain key stored';
end $$;
set role anon;
do $$
declare r jsonb; k text := current_setting('memohub.test_key');
begin
  r := memohub_api.capture_thought(k, 'Мысль: купить молоко, карта 4111 1111 1111 1111', 'sc-1');
  assert (r->>'ok')::boolean and (r->>'masked')::boolean and r->>'id' = 'thought-iphone-sc-1', r::text;
  r := memohub_api.capture_thought(k, 'Мысль: купить молоко, карта 4111 1111 1111 1111', 'sc-1');   -- retry
  assert (r->>'ok')::boolean, r::text;
  assert memohub_api.capture_thought(k, '   ')->>'error' = 'empty';
  assert memohub_api.capture_thought(k, repeat('x', 20001))->>'error' = 'too_long';
  assert memohub_api.capture_thought(k, 'x', 'bad id with spaces')->>'error' = 'bad_id';
  begin perform memohub_api.capture_thought('mh_wrong', 'x'); raise exception 'wrong key accepted';
  exception when insufficient_privilege then null; end;
  begin perform memohub_api.capture_thought(null, 'x'); raise exception 'null key accepted';
  exception when insufficient_privilege then null; end;
  -- The key does not open anything else.
  begin perform memohub_api.search('молоко'); raise exception 'anon searched';
  exception when insufficient_privilege then null; end;
  begin perform count(*) from memohub.captures; raise exception 'anon read captures';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$
declare r jsonb; i int; k text := current_setting('memohub.test_key');
begin
  assert (select count(*) from memohub.captures where source = 'shortcut' and device = 'iphone') = 1;
  assert (select content from memohub.captures where chat_ref = 'thought-iphone-sc-1') = 'Мысль: купить молоко, карта [masked:card_number]';
  assert (select uses from memohub.device_keys where device = 'iphone' and revoked_at is null) = 2;
  -- Rate limit: 30 per minute per device.
  for i in 2..30 loop perform memohub_api.capture_thought(k, 'мысль ' || i, 'sc-' || i); end loop;
  assert memohub_api.capture_thought(k, 'лишняя', 'sc-31')->>'error' = 'rate_limited';
  -- Revoke: the key stops at once; a new key works.
  assert (memohub.device_key_revoke('iphone')->>'revoked')::int = 1;
  begin perform memohub_api.capture_thought(k, 'после отзыва'); raise exception 'revoked key accepted';
  exception when insufficient_privilege then null; end;
  assert jsonb_array_length(memohub.device_keys_list()) = 1;
  -- forget_chat works per thought.
  assert (memohub.forget_chat('thought-iphone-sc-2', true)->>'ok')::boolean;
  delete from memohub.captures where source = 'shortcut';   -- keep the backup roundtrip counts stable
end $$;
select set_config('memohub.test_key', '', false);

-- A3: health report from the database.
do $$
declare r jsonb; x jsonb;
begin
  perform memohub.capture_batch('{"device": "home-mac", "items": [{"source": "codex", "chat_ref": "codex-h1",
    "role": "user", "event_at": "2026-11-08T12:00:00Z", "key": "codex-h1:1", "content": "health"}],
    "sources": [{"source": "codex"}, {"source": "meeting", "error": "Operation not permitted"}]}');
  r := memohub.health();
  assert r ? 'capture_sources' and r ? 'notes' and r ? 'journal' and r ? 'storage', r::text;
  select x2 into x from jsonb_array_elements(r->'capture_sources') x2 where x2->>'source' = 'meeting';
  assert x->>'error' = 'Operation not permitted', x::text;            -- still failing
  select x2 into x from jsonb_array_elements(r->'capture_sources') x2 where x2->>'source' = 'codex';
  assert x->>'error' is null and (x->>'recent')::int >= 1, x::text;
  -- An error followed by a successful scan is not reported any more (now() is fixed inside one
  -- transaction, so the error is moved back an hour first).
  update memohub.capture_sources set last_error_at = now() - interval '1 hour' where source = 'meeting';
  perform memohub.capture_batch('{"device": "home-mac", "sources": [{"source": "meeting"}]}');
  select x2 into x from memohub.health() h, jsonb_array_elements(h->'capture_sources') x2 where x2->>'source' = 'meeting';
  assert x->>'error' is null, x::text;
  assert (r->'notes'->>'active')::int > 0 and (r->>'database_limit_bytes')::bigint = 524288000, r::text;
  assert not has_function_privilege('authenticated', 'memohub.health(int)', 'execute');
  delete from memohub.captures where chat_ref = 'codex-h1';
end $$;

-- 0.5: candidates. Only _propose creates them, only from captures that were sent; a human
-- approves through save() or rejects; forget and forget_chat take them away.
do $$
declare
  r jsonb; c1 uuid; c2 uuid; c3 uuid; c4 uuid; t1 uuid; t2 uuid; cand uuid; cand2 uuid; v_note uuid;
  sent uuid[];
begin
  perform memohub.capture_batch('{"device": "home-mac", "items": [
    {"source": "claude-code", "chat_ref": "cc-cand1", "role": "user", "event_at": "2026-11-08T09:00:00Z", "key": "cand-1", "content": "Решили хранить кандидатов отдельно"},
    {"source": "claude-code", "chat_ref": "cc-cand1", "role": "assistant", "event_at": "2026-11-08T09:01:00Z", "key": "cand-2", "content": "Да, отдельная таблица"},
    {"source": "codex", "chat_ref": "codex-cand2", "role": "user", "event_at": "2026-11-08T09:02:00Z", "key": "cand-3", "content": "План бега на зиму"},
    {"source": "codex", "chat_ref": "codex-cand3", "role": "user", "event_at": "2026-11-08T09:03:00Z", "key": "cand-4", "content": "Уточнили маршрут"}]}');
  select id into c1 from memohub.captures where idempotency_key = 'cand-1';
  select id into c2 from memohub.captures where idempotency_key = 'cand-2';
  select id into c3 from memohub.captures where idempotency_key = 'cand-3';
  select id into c4 from memohub.captures where idempotency_key = 'cand-4';
  sent := array[c1, c2, c3, c4];

  -- Sources must be among those sent in the run.
  r := memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'learning', 'title', 'Кандидаты отдельно'),
         'capture_ids', jsonb_build_array(c1)), array[c2]);
  assert r->>'error' = 'source_not_sent', r::text;
  r := memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'learning'),
         'capture_ids', jsonb_build_array(c1)), sent);
  assert r->>'error' = 'bad_payload', r::text;

  -- Only save() fields: control fields and anything unknown are refused.
  r := memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'learning', 'title', 'x',
         'supersedes', c1, 'note', 'sk-abcdefghijklmnopqrstuvwxyz0123'), 'capture_ids', jsonb_build_array(c1)), sent);
  assert r->>'error' = 'unknown_fields' and r->'got' ? 'supersedes' and r->'got' ? 'note', r::text;

  -- New candidate; every string in the payload is masked again, objects included.
  r := memohub._propose('00000000-0000-0000-0000-0000000000d1', jsonb_build_object('kind', 'new', 'confidence', 0.8,
         'payload', jsonb_build_object('space', 'learning', 'title', 'Кандидаты живут в отдельной таблице',
           'body_md', 'ключ sk-abcdefghijklmnopqrstuvwxyz0123', 'decisions', jsonb_build_array('пароль: hunter2xyz'),
           'entities', jsonb_build_array(jsonb_build_object('type', 'tool', 'name', 'Supabase',
             'note', jsonb_build_object('k', 'ghp_abcdefghijklmnopqrstuvwxyz0123456789')))),
         'capture_ids', jsonb_build_array(c2, c1)), sent);
  assert (r->>'ok')::boolean, r::text;
  cand := (r->>'id')::uuid;
  select payload into r from memohub.memory_candidates where id = cand;
  assert r->>'body_md' like '%[masked:credential]%' and r->>'body_md' not like '%sk-abc%', r::text;
  assert r->'decisions'->>0 like '%[masked:credential]%', r::text;
  assert r->'entities'->0->'note'->>'k' = '[masked:credential]' and r->'entities'->0->>'name' = 'Supabase', r::text;
  assert (select count(*) from memohub.candidate_sources where candidate_id = cand) = 2;

  -- The same set of captures is never proposed twice (order does not matter).
  r := memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'learning', 'title', 'Ещё раз'),
         'capture_ids', jsonb_build_array(c1, c2)), sent);
  assert r->>'error' = 'already_proposed', r::text;
  -- Per-run limit.
  r := memohub._propose('00000000-0000-0000-0000-0000000000d1', jsonb_build_object('payload',
         jsonb_build_object('space', 'learning', 'title', 'Лишний'), 'capture_ids', jsonb_build_array(c4)), sent, 1);
  assert r->>'error' = 'run_limit', r::text;

  -- candidates() lists it with its sources.
  r := memohub.candidates();
  assert (r->>'total')::int = 1 and r->'items'->0->'sources'->>'captures' = '2', r::text;

  -- Approve: saved through save() as source 'distiller'; the candidate keeps no content.
  r := memohub.approve_candidate(cand);
  assert (r->>'ok')::boolean, r::text;
  v_note := (r->>'id')::uuid;
  assert (select source from memohub.notes where id = v_note) = 'distiller';
  assert (select status = 'accepted' and payload = '{}'::jsonb and result_note_id = v_note
            from memohub.memory_candidates where id = cand);
  assert memohub.approve_candidate(cand)->>'error' = 'already_reviewed';

  -- save() checks apply: a near-duplicate title stops, the candidate stays proposed; with the
  -- user's edit new_topic it goes through.
  r := memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'learning',
         'title', 'Кандидаты живут в отдельной таблице!'), 'capture_ids', jsonb_build_array(c4)), sent);
  cand2 := (r->>'id')::uuid;
  r := memohub.approve_candidate(cand2);
  assert r->>'error' = 'similar_exists', r::text;
  assert (select status from memohub.memory_candidates where id = cand2) = 'proposed';
  r := memohub.reject_candidate(cand2, 'дубль');
  assert (r->>'ok')::boolean, r::text;
  assert (select payload = '{}'::jsonb and reject_reason = 'дубль' from memohub.memory_candidates where id = cand2);
  assert memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'learning', 'title', 'x'),
           'capture_ids', jsonb_build_array(c4)), sent)->>'error' = 'already_proposed';

  -- Amend: target_changed when the target moved on after the proposal.
  t1 := (memohub.save('{"space":"personal","title":"Маршрут пробежки по набережной","source":"claude-code","new_topic":true}')->>'id')::uuid;
  r := memohub._propose(null, jsonb_build_object('kind', 'amend', 'target_note_id', t1,
         'payload', jsonb_build_object('space', 'personal', 'title', 'Маршрут пробежки: зимний вариант'),
         'capture_ids', jsonb_build_array(c3)), sent);
  assert (r->>'ok')::boolean, r::text;
  cand := (r->>'id')::uuid;
  assert not (memohub.candidates()->'items'->0->'target'->>'target_changed')::boolean;
  perform memohub.save(jsonb_build_object('space', 'personal', 'title', 'Маршрут пробежки, правка человека',
            'source', 'claude-code', 'supersedes', t1));
  assert (memohub.candidates()->'items'->0->'target'->>'target_changed')::boolean;
  r := memohub.approve_candidate(cand);
  assert r->>'error' = 'target_changed', r::text;
  perform memohub.reject_candidate(cand);

  -- Amend that applies: the new note supersedes the target.
  t2 := (memohub.save('{"space":"personal","title":"Список книг на зиму","source":"claude-code","new_topic":true}')->>'id')::uuid;
  delete from memohub.memory_candidates where id = cand;  -- free c3 for the next proposal
  r := memohub._propose(null, jsonb_build_object('kind', 'amend', 'target_note_id', t2,
         'payload', jsonb_build_object('space', 'personal', 'title', 'Список книг на зиму, дополнен'),
         'capture_ids', jsonb_build_array(c3)), sent);
  cand := (r->>'id')::uuid;
  r := memohub.approve_candidate(cand, '{"body_md": "правка пользователя", "supersedes": "00000000-0000-0000-0000-000000000000"}');
  assert (r->>'ok')::boolean, r::text;
  assert (select supersedes = t2 and body_md = 'правка пользователя' from memohub.notes where id = (r->>'id')::uuid);
  assert (select status from memohub.notes where id = t2) = 'superseded';

  -- Exported to the other database: only the trace stays.
  r := memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'work', 'title', 'Рабочий вывод'),
         'capture_ids', jsonb_build_array(c1)), sent);
  cand := (r->>'id')::uuid;
  r := memohub.mark_candidate_exported(cand);
  assert (r->>'ok')::boolean and r->>'result_db' = 'shared', r::text;
  assert (select payload = '{}'::jsonb and status = 'accepted' from memohub.memory_candidates where id = cand);

  -- forget(note) takes the candidates that produced it or target it.
  r := memohub._propose(null, jsonb_build_object('kind', 'amend', 'target_note_id', t1,
         'payload', jsonb_build_object('space', 'personal', 'title', 'Ещё правка'), 'capture_ids', jsonb_build_array(c2)), sent);
  assert r->>'error' = 'bad_target', r::text;  -- t1 is superseded now
  perform memohub.forget(v_note, true);
  assert not exists (select 1 from memohub.memory_candidates where result_note_id = v_note);

  -- forget_chat takes candidates built on the chat; a proposal from a forgotten chat is refused.
  r := memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'personal', 'title', 'Из третьего чата'),
         'capture_ids', jsonb_build_array(c4, c2)), sent);
  cand := (r->>'id')::uuid;
  r := memohub.forget_chat('codex-cand3', true);
  assert (r->>'ok')::boolean, r::text;
  assert not exists (select 1 from memohub.memory_candidates where id = cand);
  r := memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'personal', 'title', 'Опоздавший'),
         'capture_ids', jsonb_build_array(c4)), sent);
  assert r->>'error' = 'source_gone', r::text;

  -- Owner-only: no client role may create candidates.
  assert not has_function_privilege('authenticated', 'memohub._propose(uuid, jsonb, uuid[], int)', 'execute');
  assert not has_function_privilege('anon', 'memohub._propose(uuid, jsonb, uuid[], int)', 'execute');
end $$;

-- A4: the distiller's database side. Nothing runs until distill.allow lists a source; cursors
-- move only after a recorded answer; failures mark chats and pause the distiller.
do $$
declare
  r jsonb; run uuid; m1 uuid; m2 uuid; m3 uuid; i int;
begin
  r := memohub._distill_begin('claude:sonnet');
  assert r->>'error' = 'not_enabled', r::text;
  assert memohub._distill_allow('[{"source": "nope"}]')->>'error' = 'bad_allow';
  assert memohub._distill_allow('[{"source": "codex", "extra": 1}]')->>'error' = 'bad_allow';
  r := memohub._distill_allow('[{"source": "claude-code", "project": "memohub"}]');
  assert (r->>'ok')::boolean and r->'allow'->0->>'project' = 'memohub', r::text;

  perform memohub.capture_batch(jsonb_build_object('device', 'home-mac', 'items', jsonb_build_array(
    jsonb_build_object('source', 'claude-code', 'chat_ref', 'cc-dist1', 'project_hint', 'memohub', 'role', 'user',
                       'event_at', now() - interval '5 hours', 'key', 'dist-1', 'content', 'Решили запускать дистилляцию ночью'),
    jsonb_build_object('source', 'claude-code', 'chat_ref', 'cc-dist1', 'project_hint', 'memohub', 'role', 'assistant',
                       'event_at', now() - interval '5 hours' + interval '1 minute', 'key', 'dist-2', 'content', 'Да, раз в сутки'),
    jsonb_build_object('source', 'claude-code', 'chat_ref', 'cc-dist2', 'role', 'user',
                       'event_at', now() - interval '10 minutes', 'key', 'dist-3', 'content', 'Ещё идёт'),
    jsonb_build_object('source', 'codex', 'chat_ref', 'codex-dist3', 'role', 'user',
                       'event_at', now() - interval '5 hours', 'key', 'dist-4', 'content', 'Не разрешён'))));
  select id into m1 from memohub.captures where idempotency_key = 'dist-1';
  select id into m2 from memohub.captures where idempotency_key = 'dist-2';

  r := memohub._distill_begin('claude:sonnet');
  assert (r->>'ok')::boolean, r::text;
  run := (r->>'run')::uuid;
  assert memohub._distill_begin('claude:sonnet')->>'error' = 'busy';

  -- Only allowed, quiet chats; the open chat and the codex chat wait.
  r := memohub._distill_pending(10);
  assert jsonb_array_length(r) = 1 and r->0->>'chat_ref' = 'cc-dist1' and r->0->>'project_hint' = 'memohub', r::text;
  r := memohub._distill_chat('cc-dist1');
  assert jsonb_array_length(r->'messages') = 2 and r->'messages'->0->>'id' = m1::text, r::text;

  -- Sent ids must belong to the chat.
  r := memohub._distill_record(run, 'cc-dist1', array[m1, (select id from memohub.captures where idempotency_key = 'dist-4')]);
  assert r->>'error' = 'bad_sent', r::text;
  r := memohub._distill_record(run, 'cc-dist1', array[m1, m2], jsonb_build_array(
         jsonb_build_object('confidence', 0.7, 'payload', jsonb_build_object('space', 'work', 'title', 'Дистилляция ночью'),
                            'capture_ids', jsonb_build_array(m1, m2)),
         jsonb_build_object('payload', jsonb_build_object('space', 'work', 'title', 'Повтор'),
                            'capture_ids', jsonb_build_array(m2, m1))), 0.12);
  assert jsonb_array_length(r->'proposed') = 1 and r->'refused'->>0 = 'already_proposed', r::text;
  assert (select model from memohub.memory_candidates where id = (r->'proposed'->>0)::uuid) = 'claude:sonnet';
  assert memohub._distill_pending(10) = '[]'::jsonb;

  -- A later message reopens the chat, and only the new part is sent.
  perform memohub.capture_batch(jsonb_build_object('device', 'home-mac', 'items', jsonb_build_array(
    jsonb_build_object('source', 'claude-code', 'chat_ref', 'cc-dist1', 'role', 'user',
                       'event_at', now() - interval '4 hours', 'key', 'dist-5', 'content', 'И ещё одно'))));
  select id into m3 from memohub.captures where idempotency_key = 'dist-5';
  r := memohub._distill_chat('cc-dist1');
  assert jsonb_array_length(r->'messages') = 1 and r->'messages'->0->>'id' = m3::text, r::text;

  -- Three failures mark the chat failed; it is skipped and reported.
  for i in 1..3 loop
    r := memohub._distill_fail(run, 'cc-dist1', 'bad answer');
  end loop;
  assert (r->>'failed')::boolean, r::text;
  assert memohub._distill_pending(10) = '[]'::jsonb;

  r := memohub._distill_finish(run);
  assert (r->>'ok')::boolean and not (r->>'paused')::boolean, r::text;
  r := memohub.health()->'distill';
  assert (r->>'enabled')::boolean and r->'last_run'->>'status' = 'done' and (r->'last_run'->>'chats')::int = 1
         and (r->>'failed_chats')::int = 1 and (r->>'cost_30d_usd')::numeric = 0.12, r::text;

  -- Three failed runs in a row pause it until a person clears the flag.
  for i in 1..3 loop
    run := (memohub._distill_begin('claude:sonnet')->>'run')::uuid;
    r := memohub._distill_finish(run, 'claude: not logged in');
  end loop;
  assert (r->>'paused')::boolean, r::text;
  assert memohub._distill_begin('claude:sonnet')->>'error' = 'paused';

  assert not has_function_privilege('authenticated', 'memohub._distill_record(uuid, text, uuid[], jsonb, numeric)', 'execute');
  assert not has_function_privilege('anon', 'memohub._distill_chat(text, int)', 'execute');
  assert not has_function_privilege('authenticated', 'memohub._distill_allow(jsonb)', 'execute');
  -- Similar titles from other chats, same space, same threshold as save().
  perform memohub.save('{"space":"travel","title":"Шотландия осенью: маршрут и брони","source":"claude-code","new_topic":true}');
  r := memohub._distill_similar('travel', 'Шотландия осенью: брони и маршрут, логистика');
  assert jsonb_array_length(r) = 1 and (r->0->>'similarity')::numeric >= 0.45, r::text;
  assert memohub._distill_similar('work', 'Шотландия осенью: брони и маршрут, логистика') = '[]'::jsonb;
  assert not has_function_privilege('authenticated', 'memohub._distill_similar(text, text)', 'execute');
  r := memohub._distill_resume(true);
  assert (r->>'retried_chats')::int = 1 and (memohub._distill_begin('claude:sonnet')->>'ok')::boolean, r::text;
  assert memohub._distill_pending(10)->0->>'chat_ref' = 'cc-dist1';
  perform memohub._distill_finish(r2.id) from memohub.distill_runs r2 where r2.status = 'running';
  perform memohub._distill_allow('[]');
end $$;

-- Leave one proposed candidate for the backup roundtrip.
select memohub._propose(null, jsonb_build_object('payload', jsonb_build_object('space', 'learning', 'title', 'Кандидат для бэкапа'),
         'capture_ids', jsonb_build_array(c.id)), array[c.id])
  from memohub.captures c where c.idempotency_key = 'cand-2';

-- save() accepts migration versions and Shortcut ids that happen to pass the Luhn check.
do $$
declare r jsonb;
begin
  r := memohub.save('{"space":"learning","title":"Миграция 20261108130000 и id sc-20261107190113295","source":"claude-code","new_topic":true}');
  assert (r->>'ok')::boolean, r::text;
  r := memohub.save('{"space":"learning","title":"Карта 4111 1111 1111 1111","source":"claude-code","new_topic":true}');
  assert r->>'error' = 'sensitive_data', r::text;
end $$;

select 'SMOKE OK' as result;
