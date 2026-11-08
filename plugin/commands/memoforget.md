---
description: Forget a memohub note (with all versions and files), after confirmation
argument-hint: "<what to forget: id, title or description>"
---

**First** run `select memohub.guide()` for the general rules (section "Forgetting"). Below are
only the Claude Code specifics; if they disagree with the guide, follow the guide and tell the
user.

Forget a memohub note. The user's arguments: $ARGUMENTS

1. **Which database.** Medical and sensitive personal notes: the `memohub-private` MCP (ref
   `$MEMOHUB_PRIVATE_REF`); everything else: `memohub` (`$MEMOHUB_REF`).
2. **Find the note:** `memohub.search` / `memohub.get`. Several candidates: show them and ask
   which to forget. Nothing found: say so and stop.
3. **Preview:** `select memohub.forget('<id>')` → `confirm_required`. Show the user the versions
   (`notes`: date, title, status) and files (`files`) and warn: this cannot be undone, backup
   copies disappear when they expire. Wait for an explicit "yes"; never call `forget(id, true)`
   without it.
4. **Delete:** `select memohub.forget('<id>', true)`.
5. **Storage files:** for each path in `storage_paths`,
   `supabase storage rm --experimental --project-ref "<database ref>" "ss:///files/<path>"`.
   If that fails, say the daily cleanup (`scripts/storage-gc.sh`) will delete them.
6. Reply: what was forgotten (versions, files), in which database, whether Storage files were
   deleted.
