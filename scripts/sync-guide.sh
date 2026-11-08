#!/usr/bin/env bash
# Sync clients/guide.md into memohub.guides in both databases (the version bumps only when the
# text changed). --check compares the live guides with the file and fails on drift.
set -euo pipefail
cd "$(dirname "$0")/.."

guide=clients/guide.md
sha="$(shasum -a 256 "$guide" | cut -d' ' -f1)"
targets=("" "--workdir targets/private")
names=("memohub" "memohub-private")

if [ "${1:-}" = "--check" ]; then
  status=0
  for i in 0 1; do
    live="$(supabase ${targets[$i]} db query --linked -o json 2> >(grep -v "Initialising login role" >&2) \
      "select coalesce((select sha256 from memohub.guides where key = 'main'), 'none') as sha" \
      | python3 -c 'import sys,json,re; r=sys.stdin.read(); d=json.loads(r[re.search(r"^[\[{]",r,re.M).start():]); print((d["rows"] if isinstance(d,dict) else d)[0]["sha"])')"
    if [ "$live" = "$sha" ]; then echo "ok    ${names[$i]}"; else echo "DRIFT ${names[$i]}: live ${live:0:12}, file ${sha:0:12}"; status=1; fi
  done
  exit $status
fi

sql="$(mktemp)"
trap 'rm -f "$sql"' EXIT
tag="guide_$(openssl rand -hex 6)"
{
  printf "insert into memohub.guides (key, sha256, body) values ('main', '%s', \$%s\$" "$sha" "$tag"
  cat "$guide"
  printf "\$%s\$)\n" "$tag"
  echo "on conflict (key) do update set body = excluded.body, sha256 = excluded.sha256,"
  echo "  version = memohub.guides.version + 1, updated_at = now()"
  echo "where memohub.guides.sha256 <> excluded.sha256 or memohub.guides.body <> excluded.body;"
  echo "select version, left(sha256, 12) as sha from memohub.guides where key = 'main';"
} > "$sql"

for i in 0 1; do
  printf '%-16s' "${names[$i]}"
  supabase ${targets[$i]} db query --linked -o json -f "$sql" 2> >(grep -v "Initialising login role" >&2) \
    | python3 -c 'import sys,json,re; r=sys.stdin.read(); d=json.loads(r[re.search(r"^[\[{]",r,re.M).start():]); row=(d["rows"] if isinstance(d,dict) else d)[0]; print("version", row["version"], "sha", row["sha"])'
done
