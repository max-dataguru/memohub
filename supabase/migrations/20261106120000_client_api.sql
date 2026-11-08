-- 0.4 access boundary for beta clients: Supabase Auth users listed in memohub.members call an
-- allowlist of functions over PostgREST RPC (/rest/v1/rpc/<fn>, schema memohub_api).
--
-- Design:
-- * memohub stays unexposed and owner-only; owner-mode clients (SQL via MCP) are unchanged.
-- * memohub_api holds thin SECURITY DEFINER wrappers; each checks membership first and then calls
--   the memohub function, which runs with the owner's rights. Only memohub_api goes into the
--   project's exposed schemas.
-- * Not in the API: forget (consent cannot be verified by the database, so only the owner
--   forgets), orphan_objects, storage_usage (already in catalog), helpers and trigger functions.
-- * The hybrid search overload gets its own name: PostgREST cannot pick between overloads
--   whose parameters have defaults.

create table memohub.members (
  user_id    uuid primary key,          -- auth.users.id; no FK so a restore into another project works
  label      text,
  created_at timestamptz not null default now()
);
alter table memohub.members enable row level security;
revoke all on memohub.members from public, anon, authenticated;

-- Membership of the calling Supabase Auth user. Also usable in Storage policies, hence in the API
-- schema and callable by authenticated.
create schema memohub_api;
revoke all on schema memohub_api from public;
grant usage on schema memohub_api to authenticated;

create function memohub_api.is_member()
returns boolean language sql stable security definer
set search_path = memohub, pg_catalog as $$
  select auth.uid() is not null
     and exists (select 1 from memohub.members m where m.user_id = auth.uid());
$$;

create function memohub._require_member()
returns void language plpgsql stable
set search_path = memohub, pg_catalog as $$
begin
  if not memohub_api.is_member() then
    raise exception 'not_member' using errcode = '42501',
      hint = 'Sign in as a user listed in memohub.members.';
  end if;
end $$;

-- Read wrappers (stable: callable with GET as well as POST).

create function memohub_api.catalog()
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.catalog(); end $$;

create function memohub_api.guide()
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.guide(); end $$;

create function memohub_api.search(
  q text default null, p_space text default null, p_project text default null,
  p_since date default null, p_limit int default 8, p_include_superseded boolean default false)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin
  perform memohub._require_member();
  return memohub.search(q, p_space, p_project, p_since, p_limit, p_include_superseded);
end $$;

create function memohub_api.hybrid_search(
  q text, p_query_embedding extensions.vector, p_embedding_model text,
  p_space text default null, p_project text default null, p_since date default null,
  p_limit int default 8, p_include_superseded boolean default false)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin
  perform memohub._require_member();
  return memohub.search(q, p_space, p_project, p_since, p_limit, p_include_superseded,
                        p_query_embedding, p_embedding_model);
end $$;

create function memohub_api.recent(
  p_space text default null, p_project text default null, p_limit int default 10)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.recent(p_space, p_project, p_limit); end $$;

create function memohub_api.get(p_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.get(p_id); end $$;

create function memohub_api.get_file(p_id uuid, p_offset int default 0)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.get_file(p_id, p_offset); end $$;

create function memohub_api.history(p_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.history(p_id); end $$;

create function memohub_api.by_chat(p_chat_ref text, p_include_superseded boolean default false)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.by_chat(p_chat_ref, p_include_superseded); end $$;

create function memohub_api.graph(p_type text, p_name text, p_limit int default 25)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.graph(p_type, p_name, p_limit); end $$;

create function memohub_api.check_upload(p_size_bytes bigint, p_sha256 text default null)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.check_upload(p_size_bytes, p_sha256); end $$;

-- Write wrappers (volatile: POST only).

create function memohub_api.save(p jsonb)
returns jsonb language plpgsql security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.save(p); end $$;

create function memohub_api.add_project(
  p_slug text, p_space text, p_title text, p_aliases text[] default '{}')
returns jsonb language plpgsql security definer
set search_path = memohub, pg_catalog as $$
begin
  perform memohub._require_member();
  return memohub.add_project(p_slug, p_space, p_title, p_aliases);
end $$;

create function memohub_api.put_embedding(
  p_note_id uuid, p_model text, p_embedding extensions.vector)
returns jsonb language plpgsql security definer
set search_path = memohub, pg_catalog as $$
begin
  perform memohub._require_member();
  return memohub.put_embedding(p_note_id, p_model, p_embedding);
end $$;

create function memohub_api.attach_file(p jsonb)
returns jsonb language plpgsql security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.attach_file(p); end $$;

-- Functions are executable by PUBLIC by default: take that away, then grant the API to
-- authenticated only. memohub._require_member stays owner-only (wrappers run as the owner).
revoke execute on function memohub._require_member() from public;
revoke execute on all functions in schema memohub_api from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on all functions in schema memohub_api from anon, service_role;
    revoke all on schema memohub_api from anon, service_role;
  end if;
end $$;
grant execute on all functions in schema memohub_api to authenticated;
