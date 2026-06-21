# Security

## Trust model

Agent iPhone is a **personal, local-network tool**, not an internet-facing service.

- The **bridge** listens on `0.0.0.0:<apiPort>` (default 7860) so the phone/watch
  can reach it over the LAN or a Tailnet. Anyone who can reach that port can
  attempt to pair.
- **Auth boundary:** a short-lived **pairing code** (rotating 6-digit, 24h TTL by
  default) establishes a **per-device bearer token**. Every authenticated request
  (`/command`, `/events`, `/status`, `/devices`, cmux routes) requires a valid
  device token. Tokens are individually revocable (`agent-iphone pair --revoke`).
- The **hook listener** (default 7861) is bound to **loopback only** and gated by
  a shared secret header, so Claude Code's hook traffic never crosses the network.
- `GET /health` is public (liveness only — no session data). `GET /status` and
  everything else require a token.

### Recommendations

- **Prefer Tailscale** (or a trusted home LAN) over exposing the LAN port. Do
  **not** port-forward the bridge to the public internet.
- Revoke a lost device's token with `agent-iphone pair --revoke <id>`.
- `agent-iphone uninstall --purge` removes the service, hooks, and all local data.

## Secrets

Generated at runtime, stored **outside the repo** with `0600` permissions:

- `~/Library/Application Support/claude-watch/devices.json` — per-device tokens
- `~/Library/Application Support/claude-watch/hook-secret` — hook listener secret
- `~/.config/claude-watch/cmux-password` — cmux control-socket password (if used)

The hook secret is also embedded in `~/.claude/settings.json` (in the hook
headers); `agent-iphone setup` backs that file up and `chmod 600`s it. None of
these are tracked by git (`.gitignore` guards them as defense-in-depth). **Never
commit a real token, secret, password, or pairing code.**

## Reporting a vulnerability

Please open a private report via GitHub Security Advisories on this repository,
or email the maintainer listed in the repo profile. Do not file a public issue
for anything that could expose a user's machine. We aim to acknowledge within a
few days.

This is a community project provided as-is (MIT, no warranty); there is no formal
SLA, but security reports are taken seriously.
