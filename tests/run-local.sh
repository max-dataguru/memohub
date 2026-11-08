#!/usr/bin/env bash
# Applies all migrations to a throwaway Postgres in Docker and runs the smoke test.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${MEMOHUB_TEST_PG_IMAGE:-pgvector/pgvector:pg17}"
NAME="memohub-smoke-$$"

docker run -d --rm --name "$NAME" -e POSTGRES_PASSWORD=smoke "$IMAGE" >/dev/null
trap 'docker stop "$NAME" >/dev/null' EXIT

until docker exec "$NAME" pg_isready -U postgres -q; do sleep 1; done
sleep 1

docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q < tests/storage_stub.sql
docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q < tests/auth_stub.sql

# Apply every migration in filename (= timestamp) order, as `supabase db push` does.
for f in supabase/migrations/*.sql; do
  docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q < "$f"
done
docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q -v mask_cases="$(sed 's/{{HEX40}}/0123456789abcdef0123456789abcdef01234567/g' tests/mask_cases.json)" < tests/smoke.sql
