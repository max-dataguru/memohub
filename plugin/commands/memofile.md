---
description: Save a file (PDF, ZIP, document) to memohub and attach it to a note
argument-hint: "<file path> [which note / clarification]"
---

**First** run `select memohub.guide()` for the general rules (the current version from the
database). Below are only the Claude Code specifics; if they disagree with the guide, follow the
guide and tell the user.

Save a file to memohub. The user's arguments: $ARGUMENTS

Work through the `execute_sql` MCP tool (only `memohub.*` functions) and the Supabase CLI
(`supabase login` once; the repository is not needed). No `$MEMOHUB_REF` or CLI → suggest
`/memohub-setup`.

1. **Whose document.** A company document (contracts, internal material, employer exports):
   **do not upload** it; ask for a link to it in the company system and save only the link
   (`url`). If unclear, ask.
2. **Which database.** Medical and sensitive personal files (legal cases, debts, money,
   documents, family) go to `memohub-private` (the `memohub-private` MCP, ref
   `$MEMOHUB_PRIVATE_REF`); everything else to `memohub` (`$MEMOHUB_REF`). No access to
   `memohub-private` in this session → do not upload; say it is done from a personal computer (`home-mac`).
3. **File facts** (Bash): size `stat -f %z`, `shasum -a 256`, type `file -b --mime-type`.
4. **Space check, before uploading:** `select memohub.check_upload(<size>, '<sha256>')`.
   - `duplicate` → the file is already there: do not upload; attach the existing one (or just say
     so);
   - `ok: false` (`quota_exceeded`, `file_too_large`) → **do not upload**; show the user the usage
     (`usage.human`) and the options from `hint`;
   - `warn: true` → show `message` and ask whether to upload.
5. **Text for search:** PDF, `pdftotext -layout <file> -` (no poppler: read the PDF yourself);
   DOCX/RTF, `textutil -convert txt -stdout`; TXT/MD, the content; ZIP, `unzip -l` (file list);
   images, no text. Write a `summary` (2–5 sentences: what the document is, parties, dates,
   amounts, in general terms). Do not put card, account or passport numbers in `summary`. If the
   document itself is an ID or a statement with numbers, send no `extracted_text` at all.
6. **The note.** If the user named an existing one, find it (`memohub.search`) and take its id;
   otherwise save a new one with `memohub.save` (type `note`, space/project by the contract,
   `chat_ref` = `cc-$CLAUDE_CODE_SESSION_ID`, on `same_chat` use `new_topic: true`, since a file is
   its own note) with a short description of the document.
7. **Upload:** path `<YYYY>/<MM>/<8 hex>-<name in Latin letters, [A-Za-z0-9._-]>`;
   `supabase storage cp --experimental --project-ref "$MEMOHUB_REF" "<file>" "ss:///files/<path>"`
   (for the private database, `--project-ref "$MEMOHUB_PRIVATE_REF"`).
8. **Attach:** `select memohub.attach_file($memo${"note_id": ..., "path": "<path>", "name":
   "<original name>", "summary": ..., "extracted_text": ..., "sha256": ..., "source":
   "claude-code", "device": "<$MEMOHUB_DEVICE>"}$memo$::jsonb)`. For a company document, `"url"`
   instead of `"path"`, no upload. On `sensitive_data`, remove the numbers from summary / drop
   extracted_text and retry (the file is already in storage; do not upload it again).
9. Reply: the note (title, id), the file, storage usage (`usage.human`), with a warning if
   `usage.warn`.
