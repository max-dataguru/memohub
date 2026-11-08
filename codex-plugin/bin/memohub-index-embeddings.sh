#!/usr/bin/env bash
set -euo pipefail

# Build embeddings locally with Ollama and store them via the Memohub RPC.
# Requires: supabase CLI (linked project), curl, jq.

model="${MEMOHUB_EMBEDDING_MODEL:-embeddinggemma-2:270m}"
ollama_url="${MEMOHUB_OLLAMA_URL:-$(cat "$HOME/.memohub/ollama.url" 2>/dev/null)}"
[[ -n "$ollama_url" ]] || { echo "set MEMOHUB_OLLAMA_URL or ~/.memohub/ollama.url (e.g. http://<nas>:11434)" >&2; exit 2; }
limit=0

usage() {
  cat <<'EOF'
Usage: memohub-index-embeddings.sh [--limit N]

Creates embeddings only for active notes that do not already have one for the
configured model. Text is sent only to Ollama at MEMOHUB_OLLAMA_URL.
EOF
}

if [[ "${1:-}" == "--limit" ]]; then
  [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
  limit="$2"
  shift 2
fi
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

command -v supabase >/dev/null || { echo "supabase CLI is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

query="select id, concat_ws(' ', title, body_md, decisions::text, open_questions::text, array_to_string(tags, ' '), entities::text) as text
from memohub.notes n
where n.status = 'active'
  and not exists (
    select 1 from memohub.note_embeddings e
    where e.note_id = n.id and e.model = '$model'
  )
order by n.created_at"
if [[ "$limit" -gt 0 ]]; then
  query+=" limit $limit"
fi

raw="$(supabase db query --linked --output-format json "$query")"
# The CLI wraps rows in {"boundary","rows"} for AI agents and prints a bare array otherwise.
rows="$(printf '%s\n' "$raw" | sed -n '/^[[{]/,$p' | jq -ce 'if type == "object" then .rows else . end')"
count="$(printf '%s\n' "$rows" | jq 'length')"

if [[ "$count" -eq 0 ]]; then
  echo "All active notes already have embeddings for $model."
  exit 0
fi

done_count=0
while IFS= read -r row; do
  id="$(printf '%s' "$row" | jq -r '.id')"
  note_text="$(printf '%s' "$row" | jq -r '.text')"
  payload="$(jq -cn --arg model "$model" --arg input "$note_text" '{model: $model, input: $input}')"
  embedding="$(curl --fail --silent --show-error --max-time 120 \
    "$ollama_url/api/embed" -H 'Content-Type: application/json' --data "$payload" \
    | jq -cer '.embeddings[0]')"
  dimensions="$(printf '%s' "$embedding" | jq 'length')"
  [[ "$dimensions" -eq 768 ]] || { echo "Unexpected embedding size for $id: $dimensions" >&2; exit 1; }

  vector_sql="${embedding//\'/\'\'}"
  write_query="select memohub.put_embedding('$id'::uuid, '$model', '$vector_sql'::extensions.vector);"
  supabase db query --linked --output-format json "$write_query" >/dev/null
  done_count=$((done_count + 1))
  echo "[$done_count/$count] $id"
done < <(printf '%s\n' "$rows" | jq -c '.[]')

echo "Indexed $done_count note(s) with $model through $ollama_url."
