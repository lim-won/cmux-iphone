#!/bin/bash
# configure-ios.sh — set the iOS/watchOS app's bundle identifier in ONE shot.
#
#   ./scripts/configure-ios.sh com.yourname.agentiphone
#   open ios/ClaudeWatch/ClaudeWatch.xcodeproj
#
# Updates the single AGENT_IPHONE_BUNDLE_ID build setting, from which the iPhone
# id, the Watch id (<id>.watchkitapp), and the Watch's companion id all derive.
# Edits the committed .xcodeproj directly — you do NOT need XcodeGen (that's a
# maintainer tool). project.yml is updated too so a later regenerate stays in sync.

set -euo pipefail

ID="${1:-}"
if [ -z "$ID" ]; then
  echo "Usage: $0 <bundle-id>     e.g. $0 com.yourname.agentiphone" >&2
  exit 2
fi
# Reverse-DNS sanity: letters/digits/hyphens in 2+ dot-separated segments.
if ! printf '%s' "$ID" | grep -qE '^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$'; then
  echo "Error: '$ID' is not a valid reverse-DNS bundle id (e.g. com.yourname.agentiphone)." >&2
  exit 2
fi
case "$ID" in
  *.watchkitapp) echo "Error: pass the iPhone id WITHOUT '.watchkitapp' (the watch id is derived)." >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBX="$ROOT/ios/ClaudeWatch/ClaudeWatch.xcodeproj/project.pbxproj"
YML="$ROOT/ios/ClaudeWatch/project.yml"

[ -f "$PBX" ] || { echo "Error: $PBX not found." >&2; exit 1; }

# pbxproj: AGENT_IPHONE_BUNDLE_ID = <val>;   (Debug + Release configs)
/usr/bin/sed -i '' -E "s/(AGENT_IPHONE_BUNDLE_ID = )[^;]+;/\1${ID};/g" "$PBX"
# project.yml: AGENT_IPHONE_BUNDLE_ID: <val>
[ -f "$YML" ] && /usr/bin/sed -i '' -E "s/(AGENT_IPHONE_BUNDLE_ID: ).*/\1${ID}/" "$YML"

echo "✓ Bundle id set to: $ID"
echo "    iPhone:    $ID"
echo "    Watch:     ${ID}.watchkitapp"
echo "    Companion: $ID"
echo ""
echo "Next: open ios/ClaudeWatch/ClaudeWatch.xcodeproj, set your Team on both"
echo "targets (Signing & Capabilities), and Run."
