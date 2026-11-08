-- Minimal stand-in for Supabase's API roles and auth.uid(), so the client API (memohub_api)
-- can be tested on plain Postgres. auth.uid() reads the JWT claims PostgREST sets per request.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'), '')::uuid
$$;
-- Supabase grants this; vector-typed API parameters need it.
create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
-- Supabase Storage: RLS on objects, table rights for the API roles, policies decide.
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;
alter table storage.objects enable row level security;
