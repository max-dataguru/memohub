#!/usr/bin/env bash
# End-to-end check of the beta client API (memohub_api over PostgREST RPC) on a live project.
#
#   scripts/rpc-check.sh [shared|private] <email>
#
# Signs in as a Supabase Auth user (password is asked interactively, or taken from Keychain item
# memohub-rpc-<target> if present), then checks: no token -> refused; signed in but not a member
# -> not_member; member -> catalog/save/search/hybrid_search/get work, forget and tables are not
# reachable. The user is added to memohub.members (owner SQL via the linked CLI) and stays there;
# the test note is forgotten at the end. Prints no tokens or keys.
set -euo pipefail
cd "$(dirname "$0")/.."

target="${1:-}"; email="${2:-}"
case "$target" in
  shared)  workdir=. ;;
  private) workdir=targets/private ;;
  *) echo "usage: $0 shared|private <email>" >&2; exit 2 ;;
esac
[ -n "$email" ] || { echo "usage: $0 shared|private <email>" >&2; exit 2; }

ref="$(cat "$workdir/supabase/.temp/project-ref")"
url="https://$ref.supabase.co"

owner_sql() {  # run SQL as the owner through the linked CLI, print the first row's value
  supabase --workdir "$workdir" db query --linked --output-format json "$1" 2>/dev/null \
    | sed -n '/^[[{]/,$p' | jq -r '(if type == "object" then .rows else . end)[0] | to_entries[0].value'
}

apikey="$(supabase projects api-keys --project-ref "$ref" -o json 2>/dev/null \
  | jq -r '[.[] | select(.name == "anon" or .type == "publishable")][0].api_key')"
[ -n "$apikey" ] && [ "$apikey" != null ] || { echo "no anon/publishable key for $ref" >&2; exit 1; }

password="$(security find-generic-password -a "$email" -s "memohub-rpc-$target" -w 2>/dev/null || true)"
if [ -z "$password" ]; then
  read -r -s -p "Password for $email: " password; echo
fi

auth="$(curl -s "$url/auth/v1/token?grant_type=password" -H "apikey: $apikey" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$email" --arg p "$password" '{email: $e, password: $p}')")"
unset password
token="$(jq -r '.access_token // empty' <<<"$auth")"
uid="$(jq -r '.user.id // empty' <<<"$auth")"
[ -n "$token" ] || { echo "sign-in failed: $(jq -r '.error_description // .msg // .error // "unknown"' <<<"$auth")" >&2; exit 1; }
echo "signed in: $uid"

fails=0
ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1: $2"; fails=$((fails + 1)); }

# rpc <function> <json> [token]  ->  sets $code and $body
rpc() {
  local hdr=(-H "apikey: $apikey" -H 'Content-Type: application/json' -H 'Content-Profile: memohub_api')
  [ -n "${3:-}" ] && hdr+=(-H "Authorization: Bearer $3")
  local out; out="$(curl -s -w '\n%{http_code}' "$url/rest/v1/rpc/$1" "${hdr[@]}" -d "$2")"
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
}

echo "1. no token"
rpc catalog '{}'
[[ "$code" =~ ^40[13]$ ]] && ok "catalog refused ($code)" || fail "catalog without token" "$code $body"

echo "2. signed in, not a member"
owner_sql "delete from memohub.members where user_id = '$uid' returning 1" >/dev/null || true
rpc catalog '{}' "$token"
[ "$code" = 403 ] && grep -q not_member <<<"$body" && ok "catalog -> not_member" || fail "non-member catalog" "$code $body"

echo "3. member"
owner_sql "insert into memohub.members (user_id, label) values ('$uid', 'rpc-check $email') on conflict do nothing returning 1" >/dev/null
rpc is_member '{}' "$token"
[ "$body" = true ] && ok "is_member" || fail "is_member" "$code $body"
rpc catalog '{}' "$token"
[ "$code" = 200 ] && jq -e 'has("spaces")' <<<"$body" >/dev/null && ok "catalog" || fail "catalog" "$code $body"

title="RPC check $(date +%Y%m%d-%H%M%S)"
rpc save "$(jq -n --arg t "$title" '{p: {space: "personal", type: "note", title: $t,
  body_md: "memohub RPC API check, deleted by the script.", source: "manual", new_topic: true}}')" "$token"
id="$(jq -r '.id // empty' <<<"$body" 2>/dev/null || true)"
[ "$code" = 200 ] && [ -n "$id" ] && ok "save ($id)" || fail "save" "$code $body"

if [ -n "$id" ]; then
  rpc get "$(jq -n --arg id "$id" '{p_id: $id}')" "$token"
  [ "$(jq -r '.title' <<<"$body")" = "$title" ] && ok "get" || fail "get" "$code $body"
  rpc search '{"q": "RPC check", "p_space": "personal"}' "$token"
  jq -e '.total >= 1' <<<"$body" >/dev/null && ok "search" || fail "search" "$code $body"
  rpc put_embedding "$(jq -n --arg id "$id" '{p_note_id: $id, p_model: "rpc-check-3d", p_embedding: "[1,0,0]"}')" "$token"
  jq -e '.ok' <<<"$body" >/dev/null && ok "put_embedding" || fail "put_embedding" "$code $body"
  rpc hybrid_search '{"q": "RPC check", "p_query_embedding": "[1,0,0]", "p_embedding_model": "rpc-check-3d", "p_space": "personal"}' "$token"
  jq -e '.total >= 1' <<<"$body" >/dev/null && ok "hybrid_search" || fail "hybrid_search" "$code $body"

  # Storage: upload a new object, attach it, read its text; no overwrite, no delete.
  obj="rpc-check/$(date +%Y%m%d-%H%M%S).txt"
  st() { curl -s -o /dev/null -w '%{http_code}' "$url/storage/v1/object/files/$obj" \
    -H "apikey: $apikey" -H "Authorization: Bearer $token" "$@"; }
  code="$(st -X POST -H 'Content-Type: text/plain' --data-binary 'memohub rpc check')"
  [ "$code" = 200 ] && ok "storage upload" || fail "storage upload" "$code"
  rpc attach_file "$(jq -n --arg id "$id" --arg p "$obj" '{p: {note_id: $id, path: $p, extracted_text: "memohub rpc check"}}')" "$token"
  fid="$(jq -r '.file_id // .id // empty' <<<"$body" 2>/dev/null || true)"
  jq -e '.ok' <<<"$body" >/dev/null && ok "attach_file" || fail "attach_file" "$code $body"
  if [ -n "$fid" ]; then
    rpc get_file "$(jq -n --arg id "$fid" '{p_id: $id}')" "$token"
    grep -q 'rpc check' <<<"$body" && ok "get_file" || fail "get_file" "$code $body"
  fi
  code="$(st -X POST -H 'x-upsert: true' -H 'Content-Type: text/plain' --data-binary 'overwrite')"
  [[ "$code" =~ ^4 ]] && ok "storage overwrite refused ($code)" || fail "storage overwrite" "$code"
  st -X DELETE >/dev/null
  left="$(owner_sql "select count(*) from storage.objects where bucket_id = 'files' and name = '$obj'")"
  [ "$left" = 1 ] && ok "storage delete refused" || fail "storage delete" "object count $left"
fi

echo "4. thought with a device key (publishable key only, role anon)"
pub="$(supabase projects api-keys --project-ref "$ref" -o json 2>/dev/null \
  | jq -r '[.[] | select(.type == "publishable")][0].api_key // empty')"
dkey="mh_$(openssl rand -hex 32)"
owner_sql "select memohub.device_key_create('rpc-check', '$(printf '%s' "$dkey" | shasum -a 256 | cut -d' ' -f1)')->>'ok'" >/dev/null
thought() {  # thought <key> <id> -> sets code/body
  local out; out="$(curl -s -w '\n%{http_code}' "$url/rest/v1/rpc/capture_thought" -H "apikey: ${pub:-$apikey}" \
    -H 'Content-Type: application/json' -H 'Content-Profile: memohub_api' \
    -d "$(jq -n --arg k "$1" --arg id "$2" '{p_key: $k, p_text: "rpc-check thought", p_id: $id}')")"
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
}
tid="rc$(date +%s)"
thought "$dkey" "$tid"
[ "$code" = 200 ] && jq -e '.ok' <<<"$body" >/dev/null && ok "capture_thought" || fail "capture_thought" "$code $body"
thought "mh_wrong" "x$tid"
[[ "$code" =~ ^40[13]$ ]] && ok "wrong device key refused ($code)" || fail "wrong device key" "$code $body"
owner_sql "select memohub.device_key_revoke('rpc-check')->>'ok'" >/dev/null
thought "$dkey" "y$tid"
[[ "$code" =~ ^40[13]$ ]] && ok "revoked key refused ($code)" || fail "revoked key" "$code $body"
owner_sql "select memohub.forget_chat('thought-rpc-check-$tid', true)->>'ok'" >/dev/null
unset dkey

echo "5. not reachable"
rpc forget "$(jq -n --arg id "${id:-00000000-0000-0000-0000-000000000000}" '{p_id: $id, p_confirm: true}')" "$token"
[ "$code" = 404 ] && ok "forget not in API" || fail "forget" "$code $body"
code="$(curl -s -o /dev/null -w '%{http_code}' "$url/rest/v1/notes?select=id&limit=1" \
  -H "apikey: $apikey" -H "Authorization: Bearer $token" -H 'Accept-Profile: memohub')"
[ "$code" = 406 ] && ok "schema memohub not exposed" || fail "memohub.notes via REST" "$code"
code="$(curl -s -o /dev/null -w '%{http_code}' "$url/rest/v1/members?select=user_id" \
  -H "apikey: $apikey" -H "Authorization: Bearer $token" -H 'Accept-Profile: memohub_api')"
[[ "$code" =~ ^40[34]$ ]] && ok "no tables in memohub_api ($code)" || fail "memohub_api.members" "$code"

if [ -n "${id:-}" ]; then
  owner_sql "select memohub.forget('$id'::uuid, true)->>'ok'" >/dev/null || true
  # Judge by the tombstone, not by the CLI output of the forget call.
  r="$(owner_sql "select exists (select 1 from memohub.forgotten where id = '$id') as gone")"
  [ "$r" = true ] && echo "cleanup: test note forgotten" || echo "cleanup FAILED: forget $id by hand"
fi
if [ -n "${obj:-}" ]; then
  supabase --workdir "$workdir" storage rm --experimental --linked "ss:///files/$obj" >/dev/null 2>&1 \
    && echo "cleanup: test object removed" || echo "cleanup: object $obj left, storage-gc.sh removes it"
fi
echo "member kept: $uid (remove: delete from memohub.members where user_id = '$uid')"
[ "$fails" = 0 ] && echo "RPC CHECK OK" || { echo "RPC CHECK: $fails failed"; exit 1; }
