# imsg-helper

A small, read-only tool that lets Grok Bot (or you) read your Mac’s iMessage history without granting Full Disk Access to Terminal.

## What it can do

- Read recent conversations, search message text, or dump one thread
- Cover **all** contacts, except chats you put on your blocklist
- Show contact names next to phone numbers and emails (from your Mac's Contacts, read-only)
- Print JSON to stdout

## What it cannot do

- Send, delete, or edit messages (this helper only reads)
- Edit your contacts or your blocklist
- Talk to the network
- Run in the background (it only runs when you or Grok Bot call `imsg-read`)

## What about sending?

This helper never sends. Grok Bot *can* still send a text on your Mac by a separate route: an AppleScript command (`osascript`) that tells the Messages app to send. That route needs no Full Disk Access, only the macOS **Automation → Messages** permission, which macOS asks you to allow the first time. It is not part of this repo. A bot should send only after showing you the exact recipient and text and getting your explicit yes. To turn sending off, revoke Messages under System Settings → Privacy & Security → Automation.

Message text it returns can be pasted into the Grok Bot chat. Treat that like sharing those texts with the bot.

## Why Full Disk Access (and why nothing narrower)

macOS stores Messages in `~/Library/Messages/chat.db`. That folder is protected; the only TCC permission that unlocks it is **Full Disk Access**. AppleScript for Messages can send texts but **cannot read past history**, so there is no thinner API.

## How FDA is scoped to this helper only

If you ran the binary from Terminal, macOS would treat **Terminal** as the “responsible process” and you’d have to give Terminal Full Disk Access — far broader than needed.

Instead, `install.sh` registers an on-demand LaunchAgent whose program is the helper inside a tiny `imsg-helper.app` (bundle id `com.local.imessage-helper`). `imsg-read` only writes a request file and runs `launchctl kickstart`. launchd starts the helper with **no Terminal ancestor**, so TCC attributes FDA to the helper app alone. The binary is ad-hoc code-signed; if you rebuild or update, macOS drops the old grant: remove imsg-helper from Full Disk Access, add the app again, and toggle it on.

## Install (about 5 minutes)

1. Unzip this folder onto your Mac.
2. In Terminal:

```bash
cd /path/to/imessage-helper
./install.sh
```

3. Open **System Settings → Privacy & Security → Full Disk Access**.
4. Click **+**, press **Cmd+Shift+G**, paste the path `install.sh` printed (under `~/Library/Application Support/imessage-helper/imsg-helper.app`), and toggle it **on**.
5. Test:

```bash
~/.local/bin/imsg-read recent --hours 24
```

You should see JSON with recent threads. If it times out, re-check the FDA toggle and `~/Library/Application Support/imessage-helper/agent.err.log`.

### Commands

```bash
imsg-read recent --hours 24
imsg-read search --query "dinner" --days 30
imsg-read thread --handle "+15551234567" --days 14
imsg-read thread --handle "Family Group" --days 7
imsg-read thread --handle "Jordan Sample" --days 7
imsg-read blocklist
```

Optional: `--limit N` (default 200, max 500).

`thread --handle` accepts a phone number in any format, an email, a chat identifier, a group chat name, or a contact name (full name, nickname, company, or first name). If a name matches more than one contact, it returns an error listing the candidate handles instead of guessing.

## Contact names

Every message includes `sender_name`, and every message and `recent` thread includes `chat_contact_name` (for one-on-one chats). The helper fills them by reading your Mac's Contacts database (`~/Library/Application Support/AddressBook/`, including synced sources) read-only with SQLite `query_only`, under the same Full Disk Access grant. Phones match on their last 10 digits and emails case-insensitively.

Either field is `null` when there's no match, for your own messages (`sender_name`), and for group chats (`chat_contact_name`). If Contacts can't be read, the helper keeps working and adds a top-level `warning`; names are then all `null`.

## Blocklist (you edit it, bots don't)

`~/Library/Application Support/imessage-helper/blocked.txt` lists chats and people the helper must never return. `install.sh` creates it empty (with comments) and never overwrites it. One entry per line; lines starting with `#` are comments:

```text
# a phone number, any format (matched on the last 10 digits)
+1 (555) 010-0000
# an email (case-insensitive)
someone@example.com
# a chat_identifier or a group chat name
chat123456789
Book Club
# a contact name, exactly as saved in Contacts (full name, nickname, or company)
Jordan Sample
```

The helper drops every message from a blocked chat or sender in `recent`, `search`, and `thread` before it decodes any text, so blocked content never reaches the output. A blocked person's messages are removed from group chats too; the rest of the group still shows. `thread` on a blocked chat returns an error saying it's blocked, with no content. Each response has a `blocked_count` (how many messages were dropped) and never says which entries matched.

`imsg-read blocklist` shows the file path and how many entries it has, never the entries. There is deliberately **no** command to add or remove entries: only you edit the file, so a bot can't loosen it. If the file exists but can't be read, the helper refuses to return messages.

## Uninstall

```bash
./uninstall.sh
```

Then remove **imsg-helper** from Full Disk Access in System Settings.

## Files (what you’re trusting)

| Path | Role |
|------|------|
| `Sources/main.swift` | All logic (~580 lines). Read it. |
| `imsg-read` | Bash trigger; no Messages access of its own |
| `install.sh` / `uninstall.sh` | Build, LaunchAgent, empty blocklist, cleanup |
| `tests/test_queries.py` | Tests against fake data only (`python3 tests/test_queries.py`) |

No third-party libraries. Opens `chat.db` and the Contacts databases with SQLite read-only + `query_only`.

## Credits

Contact-name resolution and blocklist ideas inspired by jeffhuber/grokbot-imessage-skill (MIT).
