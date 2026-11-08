---
name: tomemo
description: Save a summary of the current session to Memohub when the user says "tomemo", "remember the summary" (or «запомни итог») or asks to record an agreement.
---

# Saving a session summary

1. Through the `memohub` MCP run `select memohub.guide()` and follow the current rules. For a
   clearly sensitive topic, if the `memohub-private` MCP is available, use it and read the guide
   there.
2. Write a short note with decisions, context and next steps, in the language of the
   conversation. Do not save secrets, credentials, card numbers, IBANs, documents or other
   sensitive data.
3. Choose `space` and `project` from the catalog; for a work repository `project` is the git root
   name in lower case. Set `source = 'codex'`, `device` from the `DEVICE` file next to the MCP
   config, and `chat_ref` like `codex-<YYYYMMDD>-<4 random characters>`; reuse the same label in
   this session.
4. Call `memohub.save` only after the user explicitly asks to save (for example "tomemo" or
   "remember the summary"). Codex saves without showing a draft when the project is unambiguous.
   If the project is not in `catalog()`, ask whether to create it or save without a project
   (inbox). Do not change or delete existing notes.
5. Confirm briefly with the title, space/project and id.
