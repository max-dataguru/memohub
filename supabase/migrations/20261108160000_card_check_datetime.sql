-- Card-number check without false positives on date-time stamps: migration versions
-- (YYYYMMDDhhmmss, 14 digits) and Shortcut ids (…SSS, 17 digits) sometimes pass the Luhn check,
-- so save() refused notes that mention a migration and the journal masked them. A run of exactly
-- 14 or 17 digits without separators that reads as a valid date-time is not a card: no card brand
-- starts with 19xx/20xx at those lengths (Visa 4, Amex 34/37, Diners 30/36/38, Mastercard
-- 51-55 / 2221-2720). Same rule in scripts/capture.py; cases in tests/mask_cases.json.

create function memohub._is_card_number(m text)
returns boolean language plpgsql immutable set search_path = memohub, pg_catalog as $$
declare
  d text := regexp_replace(m, '\D', '', 'g');
begin
  if length(d) not between 13 and 19 or not _luhn_ok(d) then
    return false;
  end if;
  if m = d and length(d) in (14, 17)
     and d ~ '^(19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])([01]\d|2[0-3])[0-5]\d[0-5]\d(\d{3})?$' then
    return false;
  end if;
  return true;
end $$;

create or replace function memohub.sensitive_findings(t text)
returns text[]
language plpgsql immutable
set search_path = memohub, pg_catalog
as $$
declare
  kinds text[] := '{}';
  m     text;
  pat   text;
begin
  if t is null or t = '' then
    return kinds;
  end if;

  for m in select (regexp_matches(t, '(?:\d[ -]?){12,18}\d', 'g'))[1] loop
    if _is_card_number(m) then
      kinds := array_append(kinds, 'card_number');
      exit;
    end if;
  end loop;

  for m in select (regexp_matches(t, '\m[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}', 'g'))[1] loop
    if _iban_ok(m) then
      kinds := array_append(kinds, 'iban');
      exit;
    end if;
  end loop;

  if t ~* '(паспорт|passport)\D{0,30}\d{2} ?\d{2} ?\d{6}' then
    kinds := array_append(kinds, 'passport_number');
  end if;

  if t ~ '\m\d{3}-\d{3}-\d{3}[ -]\d{2}\M' then
    kinds := array_append(kinds, 'snils');
  end if;

  foreach pat in array array[
    'sk-[A-Za-z0-9_-]{20,}',                              -- OpenAI / Anthropic style keys
    'sk_(live|test)_[A-Za-z0-9]{16,}',                    -- Stripe
    'gh[pousr]_[A-Za-z0-9]{30,}', 'github_pat_[A-Za-z0-9_]{30,}',
    'xox[abprs]-[A-Za-z0-9-]{10,}',                       -- Slack
    'AKIA[0-9A-Z]{16}',                                   -- AWS access key
    'sbp_[a-f0-9]{40}',                                   -- Supabase access token
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',  -- JWT
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s@/]+@'             -- URL with user:password
  ] loop
    if t ~ pat then
      kinds := array_append(kinds, 'credential');
      exit;
    end if;
  end loop;
  if t ~* '(password|passwd|pwd|пароль)\s*[:=]\s*\S{4,}' then
    kinds := array_append(kinds, 'credential');
  end if;

  return array(select distinct k from unnest(kinds) k order by k);
end;
$$;

create or replace function memohub._mask_sensitive(t text)
returns jsonb language plpgsql immutable set search_path = memohub, pg_catalog as $$
declare
  kinds text[] := '{}';
  m     text;
  d     text;
  pat   text;
  before text;
begin
  if t is null or t = '' then
    return jsonb_build_object('text', coalesce(t, ''), 'kinds', '[]'::jsonb);
  end if;

  -- Private key blocks first, before their base64 body is looked at by other patterns.
  before := t;
  t := regexp_replace(t, '-----BEGIN [A-Z ]*PRIVATE KEY-----[A-Za-z0-9+/=\s]*(-----END [A-Z ]*PRIVATE KEY-----)?',
                      '[masked:credential]', 'g');
  if t <> before then kinds := array_append(kinds, 'credential'); end if;

  for m in select distinct (regexp_matches(t, '(?:\d[ -]?){12,18}\d', 'g'))[1] loop
    if _is_card_number(m) then
      t := replace(t, m, '[masked:card_number]');
      kinds := array_append(kinds, 'card_number');
    end if;
  end loop;

  for m in select distinct (regexp_matches(t, '\m[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}', 'g'))[1] loop
    if _iban_ok(m) then
      t := replace(t, m, '[masked:iban]');
      kinds := array_append(kinds, 'iban');
    end if;
  end loop;

  before := t;
  t := regexp_replace(t, '((?:паспорт|passport)\D{0,30})\d{2} ?\d{2} ?\d{6}', '\1[masked:passport_number]', 'gi');
  if t <> before then kinds := array_append(kinds, 'passport_number'); end if;

  before := t;
  t := regexp_replace(t, '\m\d{3}-\d{3}-\d{3}[ -]\d{2}\M', '[masked:snils]', 'g');
  if t <> before then kinds := array_append(kinds, 'snils'); end if;

  before := t;
  foreach pat in array array[
    'sk-[A-Za-z0-9_-]{20,}',
    'sk_(?:live|test)_[A-Za-z0-9]{16,}',
    'gh[pousr]_[A-Za-z0-9]{30,}', 'github_pat_[A-Za-z0-9_]{30,}',
    'xox[abprs]-[A-Za-z0-9-]{10,}',
    'AKIA[0-9A-Z]{16}',
    'sbp_[a-f0-9]{40}',
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  ] loop
    t := regexp_replace(t, pat, '[masked:credential]', 'g');
  end loop;
  t := regexp_replace(t, '([a-z][a-z0-9+.-]*://)[^\s:/@]+:[^\s@/]+@', '\1[masked:credential]@', 'g');
  t := regexp_replace(t, '((?:password|passwd|pwd|пароль)\s*[:=]\s*)\S{4,}', '\1[masked:credential]', 'gi');
  if t <> before then kinds := array_append(kinds, 'credential'); end if;

  return jsonb_build_object('text', t,
    'kinds', to_jsonb(array(select distinct k from unnest(kinds) k order by k)));
end $$;

revoke execute on function memohub._is_card_number(text), memohub.sensitive_findings(text),
  memohub._mask_sensitive(text) from public;
