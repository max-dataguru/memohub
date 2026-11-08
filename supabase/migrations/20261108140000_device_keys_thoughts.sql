-- A2 "Мысль" from an iPhone Shortcut: a device key that can only add a thought to the journal.
--
-- The Shortcut calls POST /rest/v1/rpc/capture_thought (schema memohub_api) with the project's
-- publishable key, so the function is executable by anon. It does nothing without a valid device
-- key: 256 random bits made on the owner's Mac (openssl), only its SHA-256 ever reaches the
-- database; revocation takes effect at once. A key can
-- only append to captures (source 'shortcut'); it cannot read or change anything else.
-- Rate limit per key: 30 per minute, 1000 per day. Text is masked like any capture.
-- Keys are created and revoked by the owner (scripts/device-key.sh), never over the API.

create table memohub.device_keys (
  id           uuid primary key default gen_random_uuid(),
  device       text not null,
  scope        text not null default 'capture' check (scope in ('capture')),
  key_hash     text not null unique,               -- sha256 hex of the key
  created_at   timestamptz not null default now(),
  revoked_at   timestamptz,
  last_used_at timestamptz,
  uses         bigint not null default 0
);
create unique index device_keys_active_device on memohub.device_keys (device) where revoked_at is null;
alter table memohub.device_keys enable row level security;
revoke all on memohub.device_keys from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on memohub.device_keys from anon, authenticated;
  end if;
end $$;
-- Not exported in backups: after a restore, devices get new keys.

-- Owner: register a device key by its SHA-256 (the key itself never leaves the owner's Mac);
-- revokes the device's previous key.
create function memohub.device_key_create(p_device text, p_key_hash text)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
begin
  if nullif(trim(p_device), '') is null or p_device !~ '^[a-z0-9][a-z0-9_-]{1,40}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_device', 'hint', 'Use a short slug, e.g. iphone.');
  end if;
  if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_hash', 'hint', 'sha256 hex of the key');
  end if;
  update device_keys set revoked_at = now() where device = p_device and revoked_at is null;
  insert into device_keys (device, key_hash) values (p_device, p_key_hash);
  return jsonb_build_object('ok', true, 'device', p_device);
end $$;

create function memohub.device_key_revoke(p_device text)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare n int;
begin
  update device_keys set revoked_at = now() where device = p_device and revoked_at is null;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0, 'device', p_device, 'revoked', n);
end $$;

create function memohub.device_keys_list()
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  select coalesce(jsonb_agg(jsonb_build_object('device', device, 'scope', scope, 'created_at', created_at,
           'revoked_at', revoked_at, 'last_used_at', last_used_at, 'uses', uses)
           order by device, created_at desc), '[]')
    from device_keys;
$$;

-- Anon-callable: add one thought. p_id is the Shortcut's own id for this thought, so a retry of
-- the same request does not create a duplicate.
create function memohub_api.capture_thought(p_key text, p_text text, p_id text default null)
returns jsonb language plpgsql security definer
set search_path = memohub, pg_catalog as $$
declare
  k       memohub.device_keys;
  v_mask  jsonb;
  v_id    text := coalesce(nullif(trim(p_id), ''), replace(gen_random_uuid()::text, '-', ''));
  v_key   text;
begin
  select * into k from memohub.device_keys
   where key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex')
     and revoked_at is null and scope = 'capture';
  if not found then
    raise exception 'invalid_key' using errcode = '42501';
  end if;
  if nullif(trim(p_text), '') is null then
    return jsonb_build_object('ok', false, 'error', 'empty');
  end if;
  if length(p_text) > 20000 then
    return jsonb_build_object('ok', false, 'error', 'too_long', 'max_chars', 20000);
  end if;
  if v_id !~ '^[A-Za-z0-9_.:-]{1,80}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_id');
  end if;
  if (select count(*) from memohub.captures c where c.source = 'shortcut' and c.device = k.device
        and c.created_at > now() - interval '1 minute') >= 30
     or (select count(*) from memohub.captures c where c.source = 'shortcut' and c.device = k.device
        and c.created_at > now() - interval '1 day') >= 1000 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  v_key  := 'thought-' || k.device || '-' || v_id;
  v_mask := memohub._mask_sensitive(p_text);
  insert into memohub.captures (source, device, chat_ref, role, event_at, idempotency_key,
                                content, content_sha256, masked)
  values ('shortcut', k.device, v_key, 'user', now(), v_key, v_mask->>'text',
          encode(sha256(convert_to(v_mask->>'text', 'UTF8')), 'hex'),
          array(select jsonb_array_elements_text(v_mask->'kinds')))
  on conflict (idempotency_key) do nothing;
  update memohub.device_keys set last_used_at = now(), uses = uses + 1 where id = k.id;
  return jsonb_build_object('ok', true, 'saved', true, 'id', v_key,
    'masked', jsonb_array_length(v_mask->'kinds') > 0);
end $$;

revoke execute on function memohub.device_key_create(text, text), memohub.device_key_revoke(text),
  memohub.device_keys_list() from public;
revoke execute on function memohub_api.capture_thought(text, text, text) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant usage on schema memohub_api to anon;
    grant execute on function memohub_api.capture_thought(text, text, text) to anon, authenticated;
  end if;
end $$;
