<p align="center">
  <img src="logo.png" width="140" alt="Agent iPhone" />
</p>

<h1 align="center"><strong>Agent iPhone</strong></h1>

<p align="center">
  Watch and control your <strong>Claude Code</strong>, <strong>Codex</strong>, and <strong>cmux</strong>
  sessions from your iPhone (and Apple Watch).<br/>
  See live terminal output, approve permission prompts, and send prompts — over your LAN or Tailscale.
</p>

https://github.com/user-attachments/assets/5f478c28-2086-4696-9d76-e43dda853201

---

## How it works (two halves)

```
   iPhone / Watch  ──HTTP+SSE──►  agent-iphone bridge (Node)  ──hooks──►  Claude Code
   (SwiftUI app)   ◄────────────  on your Mac                 ──RPC───►  cmux mirror
                                                              ──log───►  Codex
```

- **Bridge (Mac):** a small Node server (`agent-iphone`) that receives Claude Code
  hook events, mirrors live cmux workspaces, watches Codex, and serves the phone
  over HTTP + Server-Sent Events. Discovered on the LAN via Bonjour.
- **App (iPhone + Watch):** a SwiftUI app that pairs with the bridge, shows live
  sessions/terminal output, and answers permission prompts.

Everything runs **on your own machines** — no cloud, no account, no server to host.
The bridge binds the LAN; a pairing code + per-device token are the auth boundary.
**Run it over Tailscale or a trusted LAN — it is not built to face the open internet**
(see [`SECURITY.md`](SECURITY.md)).

> **cmux is optional.** With cmux installed you get the live workspace/terminal
> mirror; without it, the bridge still streams hook-based Claude/Codex sessions.

---

## Requirements

| Component | Minimum |
|-----------|---------|
| macOS | 13+ |
| Node.js | 18+ |
| Xcode | 16+ (to build the app) |
| iOS / watchOS | 17 / 10 |
| Claude Code | recent |
| cmux | optional, **0.63.2+** (uses cmux's `mobile.*` RPC) |
| Tailscale | optional (remote access) |

---

## Install — the Mac bridge

```bash
git clone https://github.com/lim-won/agent-iphone && cd agent-iphone/skill/bridge
npm ci                        # reproducible install (use `npm install` if no lockfile)
npm link                      # optional: puts `agent-iphone` on your PATH
agent-iphone setup             # or: node bin/agent-iphone.js setup
```

`agent-iphone setup` is **idempotent** (safe to re-run). It:

1. checks macOS + Node 18+, detects Claude/Codex/cmux/Tailscale,
2. writes `config.json` and generates secrets (`0600`, never rotated on re-run),
3. **backs up** `~/.claude/settings.json` and merges Agent iPhone's hooks (scoped —
   it never touches another tool's hooks),
4. picks a runner — **in-cmux** when cmux is present (so the live mirror works), or
   a **LaunchAgent** when it isn't,
5. health-checks the bridge and prints your LAN/Tailscale address + pairing code.

> **Why two runners?** A `launchd` process cannot reach the cmux control socket
> (verified). So when cmux is present the bridge runs *inside* a cmux workspace;
> otherwise it runs as a LaunchAgent serving hook/phone/Codex sessions only.

### Using the cmux mirror

For the live cmux mirror, **cmux must be running and its control socket
reachable** when you run setup (configure cmux's socket password if it uses one).
Then:

```bash
agent-iphone setup --cmux     # fails fast if cmux RPC isn't reachable (instead of half-installing)
agent-iphone doctor           # confirm:  cmux RPC = mobile.workspace.list OK
```

If cmux is installed but its socket isn't reachable, setup stops and tells you —
it won't silently start a bridge that can't mirror. To skip cmux entirely and run
hook/phone/Codex sessions only: `agent-iphone setup --launchd`.

Manage it with the CLI:

| Command | What it does |
|---|---|
| `agent-iphone setup` | install / repair (idempotent) |
| `agent-iphone doctor` | read-only diagnostics — **paste this into a GitHub issue** |
| `agent-iphone status` | bridge state, LAN/Tailscale address, cmux, paired devices |
| `agent-iphone pair` | show the pairing code · `--list` · `--revoke <id>` |
| `agent-iphone logs` | tail the bridge log |
| `agent-iphone restart` | restart the bridge |
| `agent-iphone uninstall` | remove hooks + service (`--purge` also deletes data) |

---

## Install — the iPhone / Watch app (build it yourself)

There is **no App Store / TestFlight build** — Agent iPhone is distributed as
source and you build it with your own free Apple ID. (TestFlight requires a paid
Apple Developer Program; a public binary may come later if the project enrolls.)

**1. Set your bundle id** (one command — no XcodeGen needed; the iPhone id, the
Watch id, and the Watch's companion id all derive from it):

```bash
./scripts/configure-ios.sh com.yourname.agentiphone
open ios/ClaudeWatch/ClaudeWatch.xcodeproj
```

**2. Add your Apple ID to Xcode:** Xcode → Settings → Accounts → **+** → Apple ID
(a free account works).

**3. Set the Team on BOTH targets:** select the project → for **ClaudeWatch** and
**ClaudeWatchWatch**, Signing & Capabilities → *Automatically manage signing* →
**Team = your Personal Team**. (The bundle ids are already set by step 1.)

**4. Enable Developer Mode on the iPhone (iOS 16+):** Settings → Privacy &
Security → **Developer Mode** → On → restart. (Do the same on the Watch if
deploying to it: Watch app / watchOS Settings → Privacy & Security.)

**5. Run:** plug in your iPhone (with the Watch paired), pick the **ClaudeWatch**
scheme + your iPhone as the destination → **Run** (⌘R). For the Watch app, pick
the **ClaudeWatchWatch** scheme and the paired-Watch destination (deploy via the
iPhone if direct watch install fails).

**6. Trust the developer cert:** on the iPhone, Settings → General → VPN & Device
Management → tap your developer profile → **Trust**.

> **Free-team limits:** the app expires ~**7 days** after building (re-run from
> Xcode to refresh), **no push notifications** (local notifications only), max 3
> devices. SideStore/AltStore can auto-refresh the *iPhone* app wirelessly.
>
> Maintainers: the project is generated from `project.yml` with `xcodegen` — only
> needed if you change the project structure; end users use the script above.

### Pair

1. Open the app → enter the **pairing code** from `agent-iphone pair`.
2. Same Wi-Fi → the bridge is auto-discovered (Bonjour). Otherwise enter the
   Mac's IP/Tailscale address shown by `agent-iphone status`.

Each device gets its **own token**; revoke any of them with
`agent-iphone pair --revoke <id>` (see `agent-iphone pair --list`).

> **Watch approvals (beta):** the Watch *shows* approvals but you answer them on
> the iPhone for now.

---

## Troubleshooting

Run **`agent-iphone doctor`** first — it prints a PASS/WARN/FAIL report (no
secrets) that's ideal to paste into an issue.

- **iPhone "Connection failed":** `curl http://127.0.0.1:7860/health` (note:
  `/status` requires auth). Bridge + phone must share the LAN (or Tailscale).
- **No cmux workspaces:** cmux only mirrors when the bridge runs *inside* cmux
  (`agent-iphone status` shows the runner). Without cmux you still get hook sessions.
- **Watch can't find the bridge:** same Wi-Fi; turn **off** Private Wi-Fi Address
  on the watch's network (Bonjour); or enter the IP manually.
- **Permission prompts don't appear:** confirm hooks in `~/.claude/settings.json`
  and that a device is paired (`agent-iphone pair --list`).

---

## How it works

### Event flow (Mac → phone)
Claude Code runs a tool → a `PostToolUse`/`PreToolUse` hook POSTs to the bridge →
the bridge pushes an SSE event → the app renders it.

### Permission flow (Mac → phone → Mac)
Claude hits a permission prompt → the `PermissionRequest` hook **blocks** → the
bridge pushes a `permission-request` SSE event → the phone shows the options →
your choice is POSTed back → the bridge returns the decision to Claude.
(For codex exec-approvals, the bridge types the answer into the *pinned* cmux
terminal, guarded by a screen hash — it refuses if the screen changed.)

Hooks installed (loopback listener, secret-gated): `PostToolUse`, `PreToolUse`,
`PermissionRequest` (blocking, up to 10 min), `SessionStart`, `SessionEnd`,
`Stop`, error events.

---

## Security

The bridge listens on `0.0.0.0:<port>` (LAN-reachable). Auth is the pairing code
+ per-device token; the hook listener is loopback-only and secret-gated. Secrets
live outside the repo at `0600`. Prefer Tailscale over exposing the LAN port.
Full model + reporting in [`SECURITY.md`](SECURITY.md).

## License

MIT — see [`LICENSE`](LICENSE).

Agent iPhone is a fork of [shobhit99/claude-watch](https://github.com/shobhit99/claude-watch)
(MIT); original-author copyright is preserved. See [`NOTICE.md`](NOTICE.md) for
attribution and trademark notes ("Claude" and its logo are Anthropic trademarks;
this is an independent community tool, not affiliated with Anthropic).
