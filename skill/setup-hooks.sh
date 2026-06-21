#!/bin/bash
# Cmux iPhone — Install global hooks so ALL Claude Code sessions stream to the bridge.
#
# Usage: ./setup-hooks.sh [port]
#   port: bridge server port (default: 7860)
#
# This writes HTTP hooks to ~/.claude/settings.json (global, all projects).
# To remove: ./setup-hooks.sh --remove

set -e

PORT="${1:-7860}"
BRIDGE_URL="http://127.0.0.1:${PORT}"          # phone API listener (status check)
HOOK_PORT="${CMUX_IPHONE_HOOK_PORT:-7861}"
HOOK_URL="http://127.0.0.1:${HOOK_PORT}"        # loopback hook listener (secret-gated)
SETTINGS="$HOME/.claude/settings.json"
SECRET_FILE="$HOME/Library/Application Support/cmux-iphone/hook-secret"

# Shared hook secret — must match what the bridge uses. Create it if neither the
# bridge nor a prior install has yet (the bridge honors an existing file).
if [ "$1" != "--remove" ]; then
  if [ ! -s "$SECRET_FILE" ]; then
    mkdir -p "$(dirname "$SECRET_FILE")"
    HOOK_SECRET="$(openssl rand -hex 24 2>/dev/null || (head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n'))"
    printf '%s' "$HOOK_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
  else
    HOOK_SECRET="$(cat "$SECRET_FILE")"
  fi
fi

# ── Remove mode ──────────────────────────────────────────────────────────────
if [ "$1" = "--remove" ]; then
  # Remove codex wrapper
  rm -f "$HOME/.local/bin/codex-watch" 2>/dev/null && echo "Removed codex-watch wrapper" || true

  if [ ! -f "$SETTINGS" ]; then
    echo "No settings file found at $SETTINGS"
    exit 0
  fi

  # Remove ONLY Cmux iPhone's own hooks — matched by our exact loopback origin
  # + route set, so we never delete another tool's localhost hooks.
  python3 -c "
import json, sys

with open('$SETTINGS', 'r') as f:
    settings = json.load(f)

HOOK_URL = '${HOOK_URL}'
AW_ROUTES = ('tool-output', 'pre-tool-use', 'session-start', 'session-end', 'permission', 'stop', 'error')
AW_URLS = {f'{HOOK_URL}/hooks/{r}' for r in AW_ROUTES}

hooks = settings.get('hooks', {})
changed = False
for event in list(hooks.keys()):
    new_entries = []
    for entry in hooks[event]:
        inner = entry.get('hooks')
        if not isinstance(inner, list):
            new_entries.append(entry)          # not a hook-list entry — leave untouched
            continue
        kept = [h for h in inner if h.get('url', '') not in AW_URLS]
        if len(kept) != len(inner):
            changed = True                     # we removed at least one AW hook
        if kept:
            entry['hooks'] = kept              # keep the entry + any non-AW hooks beside ours
            new_entries.append(entry)
        # else: entry contained ONLY AW hooks → drop the now-empty entry
    if new_entries:
        hooks[event] = new_entries
    else:
        del hooks[event]

if changed:
    if not hooks:
        del settings['hooks']
    with open('$SETTINGS', 'w') as f:
        json.dump(settings, f, indent=2)
    print('Cmux iPhone hooks removed from $SETTINGS')
else:
    print('No Cmux iPhone hooks found.')
"
  exit 0
fi

# ── Install mode ─────────────────────────────────────────────────────────────

echo "Installing Cmux iPhone hooks..."
echo "  Bridge URL: ${BRIDGE_URL}"
echo "  Settings:   ${SETTINGS}"
echo ""

# Verify bridge is reachable via the public /health probe (/status needs auth).
# -f makes curl fail on non-2xx so a 401/404 isn't reported as RUNNING.
if curl -sf --connect-timeout 2 "${BRIDGE_URL}/health" > /dev/null 2>&1; then
  echo "  Bridge status: RUNNING"
else
  echo "  Bridge status: NOT RUNNING (hooks will work once you start the bridge)"
fi

# Create settings file if it doesn't exist
mkdir -p "$(dirname "$SETTINGS")"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
else
  # Back up before we modify it (the hook headers embed the secret). Keep the
  # backup private — it contains the same secret as the live file.
  BACKUP="${SETTINGS}.cmuxiphone.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$BACKUP" && chmod 600 "$BACKUP"
  echo "  Backed up existing settings → ${BACKUP}"
fi

# Merge hooks into existing settings using Python (preserves existing config)
python3 -c "
import json

BRIDGE = '${HOOK_URL}'
SECRET = '${HOOK_SECRET}'
HEADERS = {'X-Cmux-Iphone-Secret': SECRET}

# The hooks we want to install
new_hooks = {
    'PostToolUse': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/tool-output',
            'headers': HEADERS,
            'timeout': 5
        }]
    }],
    # Broad approval path: mutating tools route through the bridge, which blocks
    # for phone approval only when supervise mode is ON (else auto-allows fast).
    'PreToolUse': [{
        'matcher': 'Bash|Edit|Write|MultiEdit|NotebookEdit',
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/pre-tool-use',
            'headers': HEADERS,
            'timeout': 600
        }]
    }],
    'SessionStart': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/session-start',
            'headers': HEADERS,
            'timeout': 5
        }]
    }],
    'SessionEnd': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/session-end',
            'headers': HEADERS,
            'timeout': 5
        }]
    }],
    'PermissionRequest': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/permission',
            'headers': HEADERS,
            'timeout': 600
        }]
    }],
    'Stop': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/stop',
            'headers': HEADERS,
            'timeout': 5
        }]
    }],
    'PostToolUseFailure': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/error',
            'headers': HEADERS,
            'timeout': 5
        }]
    }],
    'StopFailure': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/error',
            'headers': HEADERS,
            'timeout': 5
        }]
    }]
}

with open('$SETTINGS', 'r') as f:
    settings = json.load(f)

existing_hooks = settings.get('hooks', {})

# Cmux iPhone's own hook URLs (exact) — used to replace our prior install without
# touching another tool's localhost hooks. BRIDGE is our loopback hook origin.
AW_ROUTES = ('tool-output', 'pre-tool-use', 'session-start', 'session-end', 'permission', 'stop', 'error')
AW_URLS = {f'{BRIDGE}/hooks/{r}' for r in AW_ROUTES}

# Merge: add our hooks without removing user's existing hooks
for event, entries in new_hooks.items():
    if event not in existing_hooks:
        existing_hooks[event] = []

    # Remove ONLY our own prior hook objects (not whole mixed entries): strip AW
    # hooks from each entry's nested list, keep the entry if other hooks remain.
    deduped = []
    for entry in existing_hooks[event]:
        inner = entry.get('hooks')
        if not isinstance(inner, list):
            deduped.append(entry)
            continue
        kept = [h for h in inner if h.get('url', '') not in AW_URLS]
        if kept:
            entry['hooks'] = kept
            deduped.append(entry)
        # else: entry was only our prior hooks → drop the empty shell
    existing_hooks[event] = deduped

    # Add our new hooks
    existing_hooks[event].extend(entries)

settings['hooks'] = existing_hooks

with open('$SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)

print('Hooks installed successfully!')
print()
print('Events hooked:')
for event in new_hooks:
    print(f'  • {event}')
"

# settings.json now embeds the hook secret in the hook headers — keep it private.
chmod 600 "$SETTINGS" 2>/dev/null || true

echo ""

# ── Codex hooks ──────────────────────────────────────────────────────────────

CODEX_CONFIG="$HOME/.codex/config.toml"

if command -v codex &>/dev/null; then
  echo "Codex detected. Installing Codex hooks..."
  mkdir -p "$(dirname "$CODEX_CONFIG")"

  # Codex doesn't have HTTP hooks like Claude Code.
  # Instead, create a wrapper script that pipes --json events to the bridge.
  WRAPPER="$HOME/.local/bin/codex-watch"
  mkdir -p "$(dirname "$WRAPPER")"

  cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash
# codex-watch: Runs Codex and streams events to Cmux iPhone bridge.
# Drop-in replacement for `codex` — use `codex-watch` instead.
API_URL="http://127.0.0.1:${CMUX_IPHONE_PORT:-7860}"
HOOK_URL="http://127.0.0.1:${CMUX_IPHONE_HOOK_PORT:-7861}"
SECRET="$(cat "$HOME/Library/Application Support/cmux-iphone/hook-secret" 2>/dev/null)"

# If bridge isn't running, just run codex normally
if ! curl -s --connect-timeout 1 "${API_URL}/status" > /dev/null 2>&1; then
  exec codex "$@"
fi

# For non-exec commands (login, mcp, etc), run directly
case "$1" in
  exec|e) ;; # continue to bridge mode
  "") ;; # interactive — can't bridge, run normally
  *) exec codex "$@" ;;
esac

# Run codex exec with --json and pipe to bridge
codex "$@" --json 2>/dev/null | while IFS= read -r line; do
  TYPE=$(echo "$line" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('type',''))" 2>/dev/null || true)
  case "$TYPE" in
    item.completed)
      # Forward the whole event — let the bridge parse it
      curl -s -X POST "${HOOK_URL}/hooks/tool-output" \
        -H "Content-Type: application/json" \
        -H "X-Cmux-Iphone-Secret: ${SECRET}" \
        -d "$(echo "$line" | python3 -c "
import sys,json
e=json.load(sys.stdin)
item=e.get('item',{})
t=item.get('type','')
out={}
if t=='command_execution':
    out={'tool_name':'Bash','tool_input':{'command':item.get('command','')},'tool_output':item.get('aggregated_output',''),'source':'codex'}
elif t in ('file_edit','file_create'):
    out={'tool_name':'Edit','tool_input':{'file_path':item.get('file_path','')},'source':'codex'}
elif t=='file_read':
    out={'tool_name':'Read','tool_input':{'file_path':item.get('file_path','')},'source':'codex'}
elif t=='agent_message':
    out={'tool_name':'CodexMessage','tool_input':{},'tool_output':item.get('text',''),'source':'codex'}
if out:
    print(json.dumps(out))
else:
    print('{}')
" 2>/dev/null)" > /dev/null 2>&1 &
      ;;
    turn.completed)
      curl -s -X POST "${HOOK_URL}/hooks/stop" \
        -H "Content-Type: application/json" \
        -H "X-Cmux-Iphone-Secret: ${SECRET}" \
        -d '{"source":"codex"}' > /dev/null 2>&1 &
      ;;
  esac
done
WRAPPER_EOF

  chmod +x "$WRAPPER"
  echo "  Created: $WRAPPER"
  echo "  Use 'codex-watch exec \"prompt\"' instead of 'codex exec'"
  echo ""
else
  echo "Codex not detected — skipping Codex hooks."
  echo ""
fi

echo "Done! Sessions will stream to the bridge."
echo ""
echo "Usage:"
echo "  1. Start bridge:  cd skill/bridge && node server.js"
echo "  2. Claude Code:   just use normally (hooks auto-forward)"
echo ""
echo "To remove:  ./setup-hooks.sh --remove"
