-- Minimal stand-in for Supabase's storage schema, so migrations and file functions
-- can be tested on plain Postgres. Only the columns memohub uses.
create schema if not exists storage;
create table if not exists storage.buckets (
  id text primary key, name text, public boolean, file_size_limit bigint
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text,
  metadata jsonb,
  created_at timestamptz default now()
);
