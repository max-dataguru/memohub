#!/usr/bin/env bash
# Delete objects in bucket `files` that no memohub.files row refers to: files of forgotten notes
# and uploads never attached (older than a day, see memohub.orphan_objects). Storage objects can
# only be deleted through the Storage API, so this runs on a Mac with the Supabase CLI logged in.
#
#   storage-gc.sh [--dry-run] [shared|private ...]     default: both
set -euo pipefail
cd "$(dirname "$0")/.."

dry=0
[ "${1:-}" = --dry-run ] && { dry=1; shift; }
targets=("$@"); [ ${#targets[@]} -gt 0 ] || targets=(shared private)

for t in "${targets[@]}"; do
  dir=.; [ "$t" = private ] && dir=targets/private
  paths="$(supabase --workdir "$dir" db query --linked --output-format json \
             "select memohub.orphan_objects() as o" 2>/dev/null \
           | sed -n '/^[[{]/,$p' | jq -rn 'input | (if type == "object" then .rows else . end)[0].o[].path')" \
    || { echo "gc   $t query failed" >&2; continue; }
  if [ -z "$paths" ]; then echo "gc   $t nothing to remove"; continue; fi
  n=0
  while IFS= read -r p; do
    if [ "$dry" = 1 ]; then echo "gc   $t would remove $p"; n=$((n + 1)); continue; fi
    supabase --workdir "$dir" storage rm --experimental --linked "ss:///files/$p" >/dev/null 2>&1 \
      && n=$((n + 1)) || echo "gc   $t failed: $p" >&2
  done <<<"$paths"
  echo "gc   $t $([ "$dry" = 1 ] && echo 'would remove' || echo removed) $n"
done
