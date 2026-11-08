---
description: Save a summary of the current session to memohub (Supabase)
argument-hint: "[project or clarification]"
---

**First** run `select memohub.guide()` for the general rules (the current version from the
database). Below are only the Claude Code specifics; if they disagree with the guide, follow the
guide and tell the user.

Save a summary of this session to memohub. The user's argument (may be empty): $ARGUMENTS

Use the `execute_sql` MCP tool of the memohub server (from this plugin, `plugin:memohub:memohub`;
if it or `$MEMOHUB_REF` is missing, suggest `/memohub-setup`). Only `memohub.*` functions, no other
SQL.

**Which database.** `medicine` and sensitive personal topics (legal cases, debts and money,
documents, family, relatives' health) go to `memohub-private` (the `memohub-private` MCP server,
same functions). Everything else goes to `memohub`. No `memohub-private` server in this session →
do not save sensitive content; say it is saved from the home Mac.

Write the note in the language of the conversation.

1. `select memohub.catalog()`.
2. space: `work` if the session is about code or work; otherwise one of `personal`, `learning`,
   `medicine`, `travel`. project: for `work`, the git root name of the current folder
   (`git rev-parse --show-toplevel`, basename, lower case), unless the argument says otherwise.
   Project not in the catalog → ask whether to create it with
   `select memohub.add_project('<slug>', '<space>', '<title>', array[]::text[])` or save without a
   project (inbox).
3. Build the note:
   - `title`: specific, ≤ 200 characters;
   - `type`: `session` (session summary) or `decision` (one decision);
   - `body_md`: `## Context`, `## What was done`, `## Details` (file paths, commands, MR/PR links),
     headings in the note's language;
   - `decisions`: each understandable without this chat, with its reason; `open_questions`;
   - `tags`: 1–5, existing ones from `catalog().tags` first;
   - `entities`: `[{"type": "person|org|tool|place|topic", "name": ...}]`, who and what the note
     is about; use names from `catalog().entities` when the entity is already there;
   - `chat_ref` = `cc-` + the value of `echo $CLAUDE_CODE_SESSION_ID` (so this session's notes are
     recognized a week later, and the session can be reopened with `claude --resume <id>`);
   - `source` = `claude-code`; `device` = the value of `echo $MEMOHUB_DEVICE` (`home-mac` /
     `work-mac`); if it is empty, ask once which Mac this is and offer to set it in
     `~/.claude/settings.json` → `env`.
   - If `save` answered `same_chat` or `similar_exists`, in Claude Code **amend** by default:
     `memohub.get(id)`, one merged version, `supersedes` = id; ask only if it looks like a
     different topic (then `new_topic: true`).
   - If the session changes an earlier decision from another session, find it with
     `memohub.search` and pass `supersedes`.
4. No secrets (passwords, tokens, keys, connection strings, `.env`) and no identifiers (card,
   account and document numbers, addresses, phone numbers): generalize. On `sensitive_data`,
   rewrite without those values and save again.
5. Save right away (no draft if the project is unambiguous):
   `select memohub.save($memo${...}$memo$::jsonb)`.
   On `ok:false`, show the error to the user; never work around it with direct SQL.
6. Reply in one line: title, space/project, id.
