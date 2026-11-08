#!/usr/bin/env bash
# Leak guard for the public repository. Run by the git hooks in .githooks/ (pre-commit on the
# staged diff, pre-push on every outgoing commit and tag); CI runs gitleaks again after the push.
#   guard.sh --staged          check the staged diff
#   guard.sh <rev-list args>   check commits, e.g. origin/main..HEAD or <sha> --not --remotes
# Three checks:
#   1. gitleaks with .gitleaks.toml (tokens, keys, connection strings, project coordinates);
#   2. a local deny list that never enters git: values read from the local config (Supabase
#      project refs, backup.conf, ollama.url) plus ~/.memohub/guard.deny, one literal string per
#      line (# starts a comment);
#   3. author and committer emails must be GitHub noreply addresses (GUARD_EMAIL_RE overrides).
# Matches are reported by file and line only; the matched value is never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:?usage: guard.sh --staged | <rev-list args>}"
EMAIL_RE="${GUARD_EMAIL_RE:-@users\.noreply\.github\.com$}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

# The text under review: added lines with file names, plus commit messages.
if [ "$MODE" = --staged ]; then
  git diff --cached --no-color -U0 --no-ext-diff >"$tmp/diff"
else
  git log --no-color -p -U0 --no-ext-diff --format='commit %H%n%B' "$@" >"$tmp/diff"
fi
[ -s "$tmp/diff" ] || exit 0

# 1. gitleaks
if command -v gitleaks >/dev/null; then
  if [ "$MODE" = --staged ]; then
    gitleaks git --staged --redact -v --no-banner -l warn . || fail=1
  else
    gitleaks git --redact -v --no-banner -l warn --log-opts="$*" . || fail=1
  fi
else
  echo "guard: gitleaks not installed (brew install gitleaks)" >&2; fail=1
fi

# 2. deny list
{
  cat supabase/.temp/project-ref targets/private/supabase/.temp/project-ref 2>/dev/null || true
  echo
  if [ -f "$HOME/.memohub/backup.conf" ]; then
    grep -E '^(SHARED_HOST|SHARED_REF|PRIVATE_HOST|PRIVATE_REF|NAS_SSH|NAS_DIR)=' \
      "$HOME/.memohub/backup.conf" | cut -d= -f2- | tr -d "\"'" | tr ' ,' '\n\n'
  fi
  for f in "$HOME"/.memohub/ollama.url*; do
    [ -f "$f" ] && sed -E 's#^[a-z]+://##; s#[:/].*##' "$f"
  done
  [ -f "$HOME/.memohub/guard.deny" ] && grep -v '^\s*#' "$HOME/.memohub/guard.deny"
} | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | grep -vxE 'localhost|127\.0\.0\.1' | awk 'length >= 5' | sort -u >"$tmp/deny"

# Only added lines and commit text: removed lines may name what is being cleaned up.
awk '/^diff --git /{f=$4; sub(/^b\//,"",f); next}
     /^commit [0-9a-f]{40}$/{f="(commit " substr($2,1,8) " message)"; n=0; next}
     /^@@ /{split($3,a,","); n=substr(a[1],2)-1; next}
     /^(\+\+\+|---|index |new file|deleted file|similarity|rename |old mode|new mode|Binary )/{next}
     /^-/{next}
     {n++; print f ":" n ":" $0}' "$tmp/diff" >"$tmp/text"
if [ -s "$tmp/deny" ]; then
  hits="$(grep -iFf "$tmp/deny" "$tmp/text" | cut -d: -f1-2 | sort -u || true)"
  if [ -n "$hits" ]; then
    echo "guard: private values from the local deny list found in:" >&2
    sed 's/^/  /' <<<"$hits" >&2
    fail=1
  fi
fi

# 3. identity
if [ "$MODE" = --staged ]; then
  emails="$(git var GIT_AUTHOR_IDENT | sed -E 's/.*<(.*)>.*/\1/'; git var GIT_COMMITTER_IDENT | sed -E 's/.*<(.*)>.*/\1/')"
else
  emails="$(git log --format='%ae%n%ce' "$@")"
fi
bad="$(sort -u <<<"$emails" | grep -vE "$EMAIL_RE" | grep -v '^$' || true)"
if [ -n "$bad" ]; then
  echo "guard: $(wc -l <<<"$bad" | tr -d ' ') commit email(s) are not GitHub noreply; fix git config user.email" >&2
  fail=1
fi

[ $fail = 0 ] || { echo "guard: blocked. Fix the lines above (git commit --amend / rebase)." >&2; exit 1; }
