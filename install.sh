#!/bin/bash
# Install imsg-helper: build, package as .app, register LaunchAgent. No sudo.
set -euo pipefail

LABEL="com.local.imessage-helper"
SUPPORT="${HOME}/Library/Application Support/imessage-helper"
APP="${SUPPORT}/imsg-helper.app"
BIN="${APP}/Contents/MacOS/imsg-helper"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SCRIPT_DIR}/Sources/main.swift"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer must run on macOS." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

mkdir -p "${APP}/Contents/MacOS" "${SUPPORT}" "${HOME}/Library/LaunchAgents" "${HOME}/.local/bin"

echo "Building imsg-helper…"
TMPBIN="$(mktemp -t imsg-helper)"
swiftc -O -o "${TMPBIN}" "${SRC}"
codesign -s - --force --identifier "${LABEL}" "${TMPBIN}" 2>/dev/null || codesign -s - --force "${TMPBIN}"
mv -f "${TMPBIN}" "${BIN}"
chmod 755 "${BIN}"

# Minimal .app so TCC/FDA has a stable bundle identity (better than a bare binary on Sequoia+)
cat > "${APP}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${LABEL}</string>
  <key>CFBundleName</key>
  <string>imsg-helper</string>
  <key>CFBundleExecutable</key>
  <string>imsg-helper</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
# Ad-hoc sign the bundle so the FDA grant sticks to this identity
codesign -s - --force --deep "${APP}" 2>/dev/null || true

# LaunchAgent: on-demand only (no RunAtLoad, no KeepAlive)
cat > "${PLIST_DST}" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN}</string>
    <string>--serve</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${SUPPORT}</string>
  <key>RunAtLoad</key>
  <false/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${SUPPORT}/agent.out.log</string>
  <key>StandardErrorPath</key>
  <string>${SUPPORT}/agent.err.log</string>
</dict>
</plist>
PLIST

# Wrapper CLI
install -m 755 "${SCRIPT_DIR}/imsg-read" "${HOME}/.local/bin/imsg-read"
# Also keep a copy next to the app for the README path
install -m 755 "${SCRIPT_DIR}/imsg-read" "${SUPPORT}/imsg-read"

# Load / reload agent
UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "${PLIST_DST}"
launchctl enable "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true

echo ""
echo "Installed."
echo ""
echo "Grant Full Disk Access (required once):"
echo "  1. Open System Settings → Privacy & Security → Full Disk Access"
echo "  2. Click +, then add this app (Cmd+Shift+G and paste the path):"
echo "     ${APP}"
echo "  3. Toggle it ON"
echo ""
echo "If you rebuild later, remove the old entry and add the app again (ad-hoc signature changes)."
echo ""
echo "Test:"
echo "  ~/.local/bin/imsg-read recent --hours 24"
echo ""
