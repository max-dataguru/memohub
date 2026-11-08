#!/usr/bin/env bash
# Deploy a release tag locally. The launchd jobs (capture, backup, health) run from a separate
# checkout at the tag, never from the working copy.
#   scripts/deploy.sh vX.Y.Z              deploy; stops if the tag has unapplied migrations
#   scripts/deploy.sh vX.Y.Z --migrate    also apply pending migrations to both databases
# Order: check out the tag -> migrations -> guide -> reinstall launchd jobs -> verify.
# Rollback: deploy the previous tag. Migrations are not rolled back; write a new one instead.
# MEMOHUB_APP overrides the checkout path (default ~/.memohub/app).
set -euo pipefail

TAG="${1:-}"; MIGRATE="${2:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 vX.Y.Z [--migrate]" >&2; exit 2; }
[ -z "$MIGRATE" ] || [ "$MIGRATE" = --migrate ] || { echo "unknown option: $MIGRATE" >&2; exit 2; }

SRC="$(cd "$(dirname "$0")/.." && pwd)"   # working copy: holds the local Supabase links
APP="${MEMOHUB_APP:-$HOME/.memohub/app}"
URL="$(git -C "$SRC" remote get-url origin)"
started="$(date '+%Y-%m-%d %H:%M:%S')"

echo "== checkout $TAG -> $APP"
[ -d "$APP/.git" ] || git clone -q "$URL" "$APP"
git -C "$APP" fetch -q --tags --force origin
git -C "$APP" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "tag $TAG not on origin; push it first" >&2; exit 1; }
[ -z "$(git -C "$APP" status --porcelain --untracked-files=no)" ] || { echo "$APP has local changes; refusing" >&2; exit 1; }
prev="$(git -C "$APP" describe --tags --exact-match 2>/dev/null || echo none)"
git -C "$APP" -c advice.detachedHead=false checkout -q "refs/tags/$TAG"

# Project links are gitignored, so copy them from the working copy.
for d in supabase/.temp targets/private/supabase/.temp; do
  [ -f "$SRC/$d/project-ref" ] || { echo "missing $SRC/$d (run supabase link there)" >&2; exit 1; }
  mkdir -p "$APP/$d"; cp -p "$SRC/$d"/* "$APP/$d/"
done

echo "== migrations"
plan="$("$APP/scripts/db-push.sh" --dry-run 2>&1)" || { echo "$plan" >&2; exit 1; }
# The CLI prints JSON ({"upToDate":false,"migrations":[...]}) or, in older versions, "Would push".
if grep -qE '"upToDate": *false|Would push' <<<"$plan"; then
  grep -E '^== |"migrations"|\.sql' <<<"$plan" || true
  if [ "$MIGRATE" = --migrate ]; then "$APP/scripts/db-push.sh"
  else echo "pending migrations; rerun with --migrate (code is at $TAG, jobs not restarted)" >&2; exit 1; fi
else echo "up to date"; fi

echo "== guide"
"$APP/scripts/sync-guide.sh"
"$APP/scripts/sync-guide.sh" --check

echo "== launchd jobs"
LA="$HOME/Library/LaunchAgents"
hour() { /usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:Hour" "$LA/$1.plist" 2>/dev/null || echo "$2"; }
[ -f "$HOME/.memohub/capture.conf" ] && "$APP/scripts/install-capture.sh"
[ -f "$LA/com.memohub.backup.plist" ] && "$APP/scripts/install-mac-backup.sh" "$(hour com.memohub.backup 13)"
[ -f "$LA/com.memohub.health.plist" ] && "$APP/scripts/install-health.sh" "$(hour com.memohub.health 10)"

echo "== verify"
status=0
for l in com.memohub.capture com.memohub.backup com.memohub.health; do
  [ -f "$LA/$l.plist" ] || continue
  if ! launchctl print "gui/$(id -u)/$l" >/dev/null 2>&1; then echo "NOT loaded $l"; status=1
  elif grep -q "$APP/" "$LA/$l.plist"; then echo "ok    $l"
  else echo "WRONG path $l"; status=1; fi
done
if [ -f "$HOME/.memohub/capture.conf" ]; then
  # The capture job runs at load; give it a moment, then look for a scan after the deploy started.
  for _ in $(seq 1 30); do
    last="$(grep " scan: " "$HOME/.memohub/capture.log" 2>/dev/null | tail -1 || true)"
    [[ "${last:0:19}" > "$started" || "${last:0:19}" == "$started" ]] && break
    sleep 2
  done
  if [[ "${last:0:19}" < "$started" ]]; then echo "no scan since $started; see ~/.memohub/capture.err"; status=1
  else echo "ok    capture: ${last:20}"; fi
fi
[ $status = 0 ] && echo "deployed $TAG (was $prev)" || echo "deployed $TAG with problems (was $prev)"
exit $status
