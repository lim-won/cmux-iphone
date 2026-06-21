#!/bin/bash
# Run the Cmux iPhone bridge INSIDE cmux (a cmux workspace/surface) so it shares
# cmux's GUI login session and can reach the cmux control socket. A launchd
# agent runs in a different audit session that cmux's socket rejects, so the
# cmux-mirror feature requires the bridge to live in-session.
#
# Launch with:  cmux workspace create --name "Agent Bridge" --command "<path>/run-in-cmux.sh"
# (cmux-iphone setup registers this automatically when cmux is present.)
# Restart loop keeps the bridge up across crashes; cmux session-restore brings
# this workspace back after a cmux restart.

cd "$(dirname "$0")" || exit 1
NODE="$(command -v node || echo "$HOME/.local/bin/node")"

while true; do
  echo "[run-in-cmux] starting bridge ($(date '+%H:%M:%S'))"
  "$NODE" server.js
  echo "[run-in-cmux] bridge exited ($?), restarting in 2s…"
  sleep 2
done
