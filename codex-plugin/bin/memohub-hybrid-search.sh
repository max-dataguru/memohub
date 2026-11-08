#!/usr/bin/env bash
set -euo pipefail

# Search Memohub: hybrid (local Ollama embedding + lexical ranking) when Ollama is reachable,
# otherwise multi-query full-text search (memohub.multi_search) with the given alternatives.

model="${MEMOHUB_EMBEDDING_MODEL:-embeddinggemma-2:270m}"
ollama_url="${MEMOHUB_OLLAMA_URL:-$(cat "$HOME/.memohub/ollama.url" 2>/dev/null || true)}"
limit=8
also=()

usage() {
  cat <<'EOF'
Usage: memohub-hybrid-search.sh [--limit N] [--also <query>]... <question>

With Ollama (MEMOHUB_OLLAMA_URL or ~/.memohub/ollama.url) reachable: hybrid memohub.search.
Without it: memohub.multi_search(<question>, --also alternatives), 1-3 words each.
The output is the JSON result. Optional filters remain available through direct MCP SQL calls.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }; limit="$2"; shift 2 ;;
    --also) [[ -n "${2:-}" ]] || { usage >&2; exit 2; }; also+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
query_text="$*"

command -v supabase >/dev/null || { echo "supabase CLI is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

sql_lit() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }

embedding=""
if [[ -n "$ollama_url" ]]; then
  payload="$(jq -cn --arg model "$model" --arg input "$query_text" '{model: $model, input: $input}')"
  embedding="$(curl --fail --silent --show-error --max-time 30 \
    "$ollama_url/api/embed" -H 'Content-Type: application/json' --data "$payload" 2>/dev/null \
    | jq -cer '.embeddings[0]' 2>/dev/null)" || embedding=""
  if [[ -n "$embedding" && "$(printf '%s' "$embedding" | jq 'length')" -ne 768 ]]; then
    echo "Unexpected embedding size, falling back to multi_search" >&2
    embedding=""
  fi
  [[ -n "$embedding" ]] || echo "Ollama unreachable, falling back to multi_search" >&2
fi

if [[ -n "$embedding" ]]; then
  sql="select memohub.search($(sql_lit "$query_text"), null, null, null, $limit, false, '$embedding'::extensions.vector, '$model') as r;"
else
  arr="array[]::text[]"
  if [[ ${#also[@]} -gt 0 ]]; then
    arr="array["
    for a in "${also[@]}"; do arr+="$(sql_lit "$a"),"; done
    arr="${arr%,}]"
  fi
  sql="select memohub.multi_search($(sql_lit "$query_text"), $arr, p_limit => $limit) as r;"
fi
raw="$(supabase db query --linked --output-format json "$sql")"
printf '%s\n' "$raw" | sed -n '/^[[{]/,$p' | jq -e '(if type == "object" then .rows else . end)[0].r'
