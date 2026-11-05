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
- `imsg-read thread --handle PHONE_E164_OR_EMAIL_OR_CHAT_NAME --days N [--limit N]`: one conversation.

Each message has `date`, `text`, `is_from_me`, `sender`, `chat_name`, `chat_identifier`, `attachment_count`.

## Rules
- Read only what the user asked for; summarize instead of dumping whole threads.
- Threads show phone numbers, not contact names. Resolve names with the user's contacts, and never guess who a number belongs to.
- Never invent a message, number, or thread the helper did not return.
- This tool never sends. If the user wants to reply, show the exact draft and recipient and send only after their explicit yes, through a separate method they approve.
