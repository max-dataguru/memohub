# "Thought" Shortcut (iPhone)

A thought on the go, spoken ("Hey Siri, Thought") or sent from the Share menu of any app, goes to
the memohub journal (`captures`, source `shortcut`) in the private database. It is raw material,
like chat messages: search it with `memohub.search_captures`, forget it with
`memohub.forget_chat('thought-iphone-…')`.

The device key can only add a thought; it cannot read memory or change anything else. Limits:
30 thoughts per minute and 1000 per day. Card numbers and credentials are masked.

## Once

1. **Expose the API for the Shortcut in the private project** (Supabase → project
   `memohub-private`): Project Settings → Data API → Exposed schemas → add `memohub_api`. Do not
   add the `memohub` schema. Every other `memohub_api` function requires a signed-in member, and
   the private database has no members, so in practice only `capture_thought` is open.
2. **Device key**, in your own terminal on the Mac:
   ```
   scripts/device-key.sh create iphone
   ```
   The script shows the URL, `apikey` (the project's publishable key) and the device key `mh_…`,
   once.

## Shortcut from a ready-made file (easier)

On the Mac:
```
ref=$(cat targets/private/supabase/.temp/project-ref)
pub=$(supabase projects api-keys --project-ref "$ref" -o json | jq -r '[.[] | select(.type=="publishable")][0].api_key')
python3 -I clients/shortcut/build-shortcut.py "https://$ref.supabase.co/rest/v1/rpc/capture_thought" "$pub" /tmp/m.shortcut
shortcuts sign --input /tmp/m.shortcut --output ~/Desktop/Thought.shortcut && open ~/Desktop/Thought.shortcut
```
"Add Shortcut" → open it → in the second action replace `PASTE_DEVICE_KEY` with the `mh_…` key →
clear the terminal. iCloud brings the shortcut to the iPhone. Check on the Mac:
`shortcuts run "Thought" --input-path <text file>` shows the "Thought saved" notification.

## Shortcut by hand

Shortcuts app → "+" → name it "Thought". Actions in order:

1. **Receive input from Share Sheet** (text, URLs); if there is no input, **Ask for Input** (text,
   prompt "Thought?"). For dictation use **Dictate Text** instead.
2. **Current Date** → **Format Date**: custom format `yyyyMMddHHmmssSSS`.
3. **Random Number** between 1000 and 9999.
4. **Text**: `sc-<Formatted Date>-<Random Number>`. This is the thought's id, so repeating the same
   request does not create a duplicate.
5. **Get Contents of URL**:
   - URL from `device-key.sh`;
   - Method POST;
   - Headers: `apikey` with the publishable key; `Content-Profile` with `memohub_api`;
     `Content-Type` with `application/json`;
   - Request body JSON: `p_key` (text) with the `mh_…` key; `p_text` with the input from step 1;
     `p_id` with the text from step 4.
6. **Get Dictionary Value** for key `ok` from the reply.
7. **If** the value is `1` (or `true`) → **Show Notification** "Saved".
   **Otherwise** → **Copy to Clipboard** the input from step 1 → **Show Alert**
   "Not saved, the text is in the clipboard: <Contents of URL>".

In the shortcut settings, turn on "Show in Share Sheet". Siri runs it by name.

## Security

- The key lives only in this shortcut on the phone; the database keeps its hash. Do not share the
  shortcut: it contains the key.
- Phone lost or key leaked: run `scripts/device-key.sh revoke iphone` on the Mac and the key stops
  working at once. A new one: `create iphone` (the old one is revoked automatically).
- `scripts/device-key.sh list` shows devices, when each key was last used and how many times.
- Without a network the shortcut reports an error and leaves the text in the clipboard, so you can
  send it again.
