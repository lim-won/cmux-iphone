#!/bin/bash
# install-launchd.sh — run the Cmux iPhone bridge 24/7 as a LaunchAgent.
#
# SCOPE: this LaunchAgent serves the CORE bridge only — hook receiver, phone/SSE
# API, pairing, and Codex log monitoring. It does NOT drive the cmux live mirror:
# empirically, a launchd-spawned process cannot complete a cmux control-socket
# RPC (it fails at setsockopt; the socket is gated by the GUI session, not by the
# password). The cmux mirror requires the in-cmux supervisor (run-in-cmux.sh),
# which `cmux-iphone setup` registers as a cmux workspace when cmux is present.
#
# LaunchAgent (not LaunchDaemon) so it runs in your logged-in user session. For
# it to come back after a REBOOT untouched, enable automatic login
# (System Settings > Users & Groups > Auto-login).
#
# Usage:
#   ./install-launchd.sh [PORT]      # install + start (default port 7860)
#   ./install-launchd.sh --remove    # stop + uninstall
#
set -euo pipefail

LABEL="com.claudewatch.bridge"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/cmux-iphone"
UID_NUM="$(id -u)"

if [ "${1:-}" = "--remove" ]; then
  launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed ${LABEL}."
  exit 0
fi

PORT="${1:-7860}"
BRIDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_JS="${BRIDGE_DIR}/server.js"

# --- Resolve absolute binaries on THIS machine ---
NODE_BIN="$(command -v node || true)"
[ -z "$NODE_BIN" ] && { echo "ERROR: node not found on PATH"; exit 1; }

CMUX_BIN="$(command -v cmux || true)"
if [ -z "$CMUX_BIN" ]; then
  for c in "/Applications/cmux.app/Contents/Resources/bin/cmux"; do
    [ -x "$c" ] && CMUX_BIN="$c" && break
  done
fi
[ -z "$CMUX_BIN" ] && echo "WARN: cmux not found — prompt injection will fall back to detached runs."

# Build a PATH that covers node, claude, codex, cmux, and system tools (lsof).
PATH_ENTRIES="$(dirname "$NODE_BIN"):/usr/local/bin:/opt/homebrew/bin:${HOME}/.npm-global/bin:${HOME}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[ -n "$CMUX_BIN" ] && PATH_ENTRIES="$(dirname "$CMUX_BIN"):${PATH_ENTRIES}"

mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

# --- Write the plist ---
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${NODE_BIN}</string>
        <string>${SERVER_JS}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${BRIDGE_DIR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${PATH_ENTRIES}</string>
        <key>PORT</key>
        <string>${PORT}</string>
$([ -n "$CMUX_BIN" ] && printf '        <key>CMUX_BIN</key>\n        <string>%s</string>\n' "$CMUX_BIN")
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/bridge.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/bridge.err.log</string>
</dict>
</plist>
PLIST_EOF

# --- (Re)load ---
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
launchctl kickstart -k "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true

echo "Installed and started ${LABEL} (port ${PORT})."
echo "  node:   ${NODE_BIN}"
echo "  cmux:   ${CMUX_BIN:-<none>}"
echo "  logs:   ${LOG_DIR}/bridge.out.log"
echo ""
echo "Pairing code is printed in the log — read it with:"
echo "  grep -A4 'AGENT IPHONE BRIDGE' '${LOG_DIR}/bridge.out.log' | tail -6"
echo ""
echo "Reminders:"
echo "  • Keep awake:  sudo pmset -a sleep 0 && sudo pmset -a disablesleep 1"
echo "  • Reboot survival: enable Automatic Login for this user."
echo "  • Hooks: run ./setup-hooks.sh ${PORT} once so Claude streams to the bridge."
