# imsg-helper

A small, read-only tool that lets Grok Bot (or you) read your Mac’s iMessage history without granting Full Disk Access to Terminal.

## What it can do

- Read recent conversations, search message text, or dump one thread
- Cover **all** contacts (no allowlist)
- Print JSON to stdout

## What it cannot do

- Send, delete, or edit messages
- Talk to the network
- Run in the background (it only runs when you or Grok Bot call `imsg-read`)

Message text it returns can be pasted into the Grok Bot chat. Treat that like sharing those texts with the bot.

## Why Full Disk Access (and why nothing narrower)

macOS stores Messages in `~/Library/Messages/chat.db`. That folder is protected; the only TCC permission that unlocks it is **Full Disk Access**. AppleScript for Messages can send texts but **cannot read past history**, so there is no thinner API.

## How FDA is scoped to this helper only

If you ran the binary from Terminal, macOS would treat **Terminal** as the “responsible process” and you’d have to give Terminal Full Disk Access — far broader than needed.

Instead, `install.sh` registers an on-demand LaunchAgent whose program is the helper inside a tiny `imsg-helper.app` (bundle id `com.local.imessage-helper`). `imsg-read` only writes a request file and runs `launchctl kickstart`. launchd starts the helper with **no Terminal ancestor**, so TCC attributes FDA to the helper app alone. The binary is ad-hoc code-signed; if you rebuild, grant FDA again.

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
```

Optional: `--limit N` (default 200, max 500).

## Uninstall

```bash
./uninstall.sh
```

Then remove **imsg-helper** from Full Disk Access in System Settings.

## Files (what you’re trusting)

| Path | Role |
|------|------|
| `Sources/main.swift` | All logic (~280 lines). Read it. |
| `imsg-read` | Bash trigger; no Messages access of its own |
| `install.sh` / `uninstall.sh` | Build, LaunchAgent, cleanup |

No third-party libraries. Opens `chat.db` with SQLite read-only + `query_only`.
