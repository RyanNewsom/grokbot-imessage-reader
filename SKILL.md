---
name: imessage-reader
description: Use when the user asks you to read, search, or catch up on their iMessages on a Mac where imsg-helper is installed.
---
# iMessage reader (read-only)

This helper reads `~/Library/Messages/chat.db` on the user's own Mac. It cannot send, edit, or delete messages and makes no network calls. Full Disk Access is granted only to the helper app, not to Terminal.

## Setup (once, on the user's Mac)
1. Clone this repo and run `./install.sh` (no sudo; needs Xcode Command Line Tools).
2. The user adds the printed `imsg-helper.app` path under System Settings > Privacy & Security > Full Disk Access and turns it on. Only the user can do this.
3. Test: `~/.local/bin/imsg-read recent --hours 24` should print JSON with `"ok": true`.

## Commands (run on the user's Mac; output is JSON)
- `imsg-read recent --hours N [--limit N]`: threads with messages in the last N hours.
- `imsg-read search --query TEXT --days N [--limit N]`: messages containing TEXT.
- `imsg-read thread --handle PHONE_EMAIL_CHAT_OR_CONTACT_NAME --days N [--limit N]`: one conversation. Accepts a contact name; if it's ambiguous, the result has `"ambiguous": true` and `candidates` (name + handles). Ask the user which one, then retry with that handle.
- `imsg-read blocklist`: shows the blocklist path and entry count only.

Each message has `date`, `text`, `is_from_me`, `sender`, `sender_name`, `chat_name`, `chat_identifier`, `chat_contact_name`, `attachment_count`. Every response has `blocked_count`, and may have a top-level `warning` (for example, Contacts couldn't be read).

## Rules
- Read only what the user asked for; summarize instead of dumping whole threads.
- `sender_name` and `chat_contact_name` come from the user's Contacts and may be `null`. When a name is null, refer to the number or email; never guess who it belongs to.
- The blocklist (`~/Library/Application Support/imessage-helper/blocked.txt`) is edited only by the user. Never edit, move, or delete it, never write to it through any route, and never suggest unblocking or removing entries. A `"blocked": true` error means the user hid that chat: tell them it's blocked and stop; don't try other handles or names to get around it. Don't speculate about what `blocked_count` hides.
- Never invent a message, number, or thread the helper did not return.
- This tool never sends. Sending is a separate route: `osascript` telling the Messages app to send, which needs the user's Automation → Messages permission. Use it only after showing the exact recipient and full text and getting the user's explicit yes for that message.
