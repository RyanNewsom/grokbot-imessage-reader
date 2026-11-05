#!/bin/bash
# Remove imsg-helper files and LaunchAgent. No sudo. Reminds you to clear FDA.
set -euo pipefail

LABEL="com.local.imessage-helper"
SUPPORT="${HOME}/Library/Application Support/imessage-helper"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"

if [[ "$(uname -s)" == "Darwin" ]]; then
  launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
fi
rm -f "${PLIST_DST}"
rm -f "${HOME}/.local/bin/imsg-read"
rm -rf "${SUPPORT}"

echo "Removed LaunchAgent, ~/.local/bin/imsg-read, and:"
echo "  ${SUPPORT}"
echo ""
echo "Also remove Full Disk Access manually:"
echo "  System Settings → Privacy & Security → Full Disk Access → remove imsg-helper"
