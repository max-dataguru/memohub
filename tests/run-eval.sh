#!/usr/bin/env bash
# Search and dedup eval (0.6) on a throwaway Postgres: all migrations, then tests/eval/cases.json.
# Thresholds (baseline 08.11: hit@1 0.933, hit@5 1.0, MRR 0.967; 1 dedup false alarm):
# EVAL_MIN_HIT5 0.95, EVAL_MIN_MRR 0.93, EVAL_MAX_DEDUP_FP 1.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${MEMOHUB_TEST_PG_IMAGE:-pgvector/pgvector:pg17}"
NAME="memohub-eval-$$"
docker run -d --rm --name "$NAME" -e POSTGRES_PASSWORD=eval "$IMAGE" >/dev/null
trap 'docker stop "$NAME" >/dev/null' EXIT
until docker exec "$NAME" pg_isready -U postgres -q; do sleep 1; done
sleep 1
for f in tests/storage_stub.sql tests/auth_stub.sql supabase/migrations/*.sql; do
  docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q < "$f" >/dev/null 2>&1 \
    || { echo "failed: $f" >&2; exit 1; }
done
docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q \
  -v cases="$(cat tests/eval/cases.json)" -v min_hit5="${EVAL_MIN_HIT5:-0.95}" -v min_mrr="${EVAL_MIN_MRR:-0.93}" \
  -v max_dedup_fp="${EVAL_MAX_DEDUP_FP:-1}" \
  < tests/eval/search_eval.sql 2>&1 | sed 's/^psql:[^ ]* NOTICE: *//; s/^NOTICE: *//'
