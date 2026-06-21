The audit details are confirmed against the actual code. I have everything I need. Writing the design document now.

---

# cmux-iphone — OSS-Readiness Design Document

Tech-lead spec. Grounded entirely in the code audit + empirical research above. Where the empirical launchd test or Apple-membership facts override the owner's plan, that is called out explicitly.

---

## 1. Executive Summary

`cmux-iphone` is a per-user macOS bridge (pure-JS Node ESM, one dependency `bonjour-service`, no native bindings) that relays Claude Code / Codex / cmux sessions to an iPhone + Apple Watch app. The codebase is fundamentally sound: secrets are generated at runtime with `0600` perms, paths are `os.homedir()`-relative, a lockfile is committed. It is **not** OSS-ready due to one shipped credential, scattered config, an over-broad hook remover, and — most importantly — a run-topology assumption that the empirical test disproves.

The owner's plan is ~80% correct. Three decisions change:

**DECISION 1 — The owner leans "LaunchAgent-only." That is wrong for the cmux mirror, and it is now proven, not theorized.** Empirical test on this Mac (cmux 0.63.2, reproduced 4×): a `launchctl bootstrap gui/$UID` process **cannot complete a cmux RPC** — it fails at `setsockopt(SO_RCVTIMEO)` with `Error: Failed to configure socket receive timeout`, exit 1, on `ping` and every `rpc`. The identical command from a cmux-app-descendant shell succeeds. The socket password is a **no-op** here (RPC succeeded with *and* without it; access is gated by Unix-socket file ownership, not auth). So "we added a password, a daemon can now authenticate" is a false inference. **Ship a split topology: LaunchAgent for the always-on hook/phone server; in-cmux supervisor for the live cmux mirror.** (§2)

**DECISION 2 — No TestFlight, no public link. Drop it from the roadmap entirely.** The owner's free personal team (S5F357QXBC) cannot use TestFlight, external testers, public links, Ad Hoc, or signed-IPA distribution — all are paid-program ($99/yr) features per Apple's own membership comparison. The realistic OSS path is **build-it-yourself in Xcode**, which the repo already supports. The roadmap's "TestFlight public link" milestone is impossible and must become "document the clone+build flow honestly." (§7)

**DECISION 3 — `npm ci --omit=dev` is the right idea for our scripts but is NOT how Homebrew installs Node CLIs.** Brew's `std_npm_args` does a `--global` install into `libexec` (not `npm ci`, not `--omit=dev`). And there is **no `bin` field** in `package.json`, so the textbook `bin.install_symlink` produces *zero* executables. The formula must write its own ESM-safe wrapper (`exec node libexec/server.js`). Use `npm ci --omit=dev` in our own `setup.sh` / CI tarball build, not in the formula's logic assumption. (§6)

Everything else in the plan (one CLI, central `config.json`, surgical `--remove`, idempotent `setup`, doctor for issue-paste, personal tap, CI formula bump) is correct and kept.

---

## 2. Run Topology Decision (definitive)

**Verdict: split topology. Do not gate the whole bridge on cmux. Do not ship LaunchAgent-only.**

The bridge has two independent feature sets:
- **Core (no cmux dependency):** hook receiver on `127.0.0.1:7861`, phone/SSE API on `0.0.0.0:7860`, pairing, Codex jsonl/log monitoring, Bonjour. Works fine from a LaunchAgent in `gui/$UID`.
- **cmux live mirror (cmux dependency):** workspace/terminal mirror + prompt/approval injection via the cmux control socket. **Only a cmux-app-descendant process can drive it** (empirical, §1 DECISION 1).

### Shipping topology

```
                    ┌─────────────────────────────────────────┐
   iPhone / Watch ──┤  cmux-iphone core (LaunchAgent)          │
   (LAN/Tailnet)    │  com.cmuxiphone.bridge                   │
                    │  0.0.0.0:7860 API + 127.0.0.1:7861 hooks │
                    │  cmux features auto-OFF (degrade)        │
                    └───────────────┬─────────────────────────┘
                                    │ localhost RPC proxy (optional)
                    ┌───────────────┴─────────────────────────┐
   cmux GUI app ────┤  cmux-iphone cmux helper (in-cmux)       │
   (logged-in)      │  run-in-cmux.sh supervisor loop          │
                    │  ONLY this can complete cmux socket RPC  │
                    └───────────────────────────────────────────┘
```

Two supported shapes, owner picks one for v0.1.0 — **I recommend Shape A** for simplicity:

- **Shape A (recommended for v0.1.0): single in-cmux process when cmux is present, LaunchAgent when absent.** If cmux is detected at setup time, the bridge runs *only* as the in-cmux supervisor (`run-in-cmux.sh`), which serves BOTH core + mirror (it's a cmux descendant, so it can do everything). If cmux is absent, the bridge runs as a LaunchAgent serving core-only. One process, no proxy, no double-port-bind risk. The trade-off: when cmux is the runner, reboot survival depends on cmux session-restore re-creating the workspace (cmux already does this; `run-in-cmux.sh:8` documents it).
- **Shape B (later): always-on LaunchAgent core + optional in-cmux RPC proxy.** LaunchAgent owns the port; a thin in-cmux helper exposes cmux RPC over localhost that the LaunchAgent calls. More robust reboot survival, but introduces an IPC hop and a second moving part. Defer to post-v0.1.0.

`cmux.js` already feature-detects via `cmuxAvailable()` and returns `{available:false, workspaces:[]}` when cmux is unreachable (server.js ~1816), so degradation is graceful and already implemented.

### How `cmux-iphone setup` handles cmux-present vs cmux-absent

```
setup detects cmux binary (CMUX_BIN env → which cmux → /Applications/cmux.app/...):
  ├─ cmux PRESENT:
  │    config.cmux.enabled = true
  │    runner = "cmux"   → register a cmux workspace running run-in-cmux.sh
  │                        (cmux workspace create --name "Agent Bridge" --command <abs path>)
  │    harden cmux.js: read ~/.local/state/cmux/last-socket-path → export CMUX_SOCKET_PATH
  │    print: "cmux mirror: ON"
  └─ cmux ABSENT:
       config.cmux.enabled = false
       runner = "launchd" → install LaunchAgent (core only)
       print: "cmux mirror: OFF (cmux not found) — hook/phone sessions only"
```

This matches the memory note: **fall back to hook-only sessions when cmux is absent.** The hook + phone + Codex feature set is fully functional without cmux.

### Required fixes to make the topology honest
- **`run-in-cmux.sh:7,12`** — remove personal path in the comment and the hardcoded `/Users/limseungwon/.local/bin/node`; use `NODE="$(command -v node || echo "$HOME/.local/bin/node")"`.
- **`install-launchd.sh` header comment** — currently claims cmux works from a LaunchAgent. It does not (empirical). Rewrite to: "LaunchAgent serves core (hooks/phone/Codex) only; the cmux live mirror requires the in-cmux supervisor."
- **`cmux.js:54-70`** — `withAuth()` reads the password but **never sets `CMUX_SOCKET_PATH`**. On this install the socket is at a non-default path; an outside-env process gets "Socket not found." Add: read `~/.local/state/cmux/last-socket-path` and export `CMUX_SOCKET_PATH` (don't rely solely on inherited env). Keep `--password` (harmless, future-proofs against cmux enforcing it).
- **`REMOTE-SETUP.md:18`** currently points users at `install-launchd.sh` as the path — reconcile to the runner the setup chose.

---

## 3. Repository Restructure

Target: a self-contained `cmux-iphone/` package that becomes the release tarball (CI ships *only this subtree*, not the whole repo with the iOS app + 6.8MB `recording.mp4`).

### Target layout

```
cmux-iphone/                      ← NEW package root; CI tarball = this dir
├── package.json                  ← add "bin": { "cmux-iphone": "./bin/cmux-iphone.js" }
├── package-lock.json             ← keep (lockfileVersion 3)
├── bin/
│   └── cmux-iphone.js            ← NEW CLI dispatcher (#!/usr/bin/env node)
├── bridge/
│   ├── server.js                 ← from skill/bridge/server.js (constants → config loader)
│   ├── cmux.js                   ← from skill/bridge/cmux.js (+ CMUX_SOCKET_PATH fix)
│   ├── codex-app-server.js       ← from skill/bridge/ (clean, move as-is)
│   ├── webclient.html            ← fix :410 placeholder to read injected port
│   └── config.js                 ← NEW shared config loader (read/write config.json)
├── commands/                     ← one module per CLI verb
│   ├── setup.js  doctor.js  status.js  pair.js  logs.js  restart.js  uninstall.js
├── templates/
│   ├── com.cmuxiphone.bridge.plist.tmpl   ← from install-launchd.sh's heredoc
│   ├── run-in-cmux.sh                      ← from skill/bridge/ (cleaned)
│   └── codex-watch.tmpl                     ← from setup-hooks.sh:227-284 heredoc
├── lib/
│   └── hooks.js                  ← Claude settings.json merge/remove (replaces setup-hooks.sh python)
└── test/
    ├── unit/                     ← codex-approval-select.test.mjs + config + hook-scope tests
    └── integration/             ← approval-safety.test.mjs (read port from config, not :7860)
```

### What moves where

| From | To | Notes |
|---|---|---|
| `skill/bridge/server.js` | `bridge/server.js` | Replace inline constants (`:64-69`, `:163-168`, `:78-79`) with `config.js` reads |
| `skill/bridge/cmux.js` | `bridge/cmux.js` | Add `CMUX_SOCKET_PATH` resolution; drop `cmux 2.app` candidate (`:38`) |
| `skill/bridge/codex-app-server.js` | `bridge/codex-app-server.js` | As-is (audited clean) |
| `skill/bridge/webclient.html` | `bridge/webclient.html` | Templatize the `:410` host:port placeholder |
| `skill/bridge/install-launchd.sh` | `templates/...plist.tmpl` + `commands/setup.js` logic | No more standalone installer; CLI writes the plist |
| `skill/bridge/run-in-cmux.sh` | `templates/run-in-cmux.sh` | Cleaned (§2) |
| `skill/setup-hooks.sh` (python merge/remove + codex-watch heredoc) | `lib/hooks.js` + `templates/codex-watch.tmpl` | Reimplement scoped (§4); single source of HOOK_PORT/secret path |
| `skill/setup.sh` | `commands/setup.js` | `npm ci` not `npm install` |
| `skill/SKILL.md` + `.claude/skills/.../SKILL.md` | keep skill, reconcile naming, drop `node-pty` claim | The two diverge ("Claude Watch" vs "Cmux iPhone") — unify |

### New `config.json` schema

Single source of truth at `~/Library/Application Support/cmux-iphone/config.json`. Replaces constants scattered across server.js, setup-hooks.sh (×3 copies of hook-secret path), install-launchd.sh, and the Swift clients.

```jsonc
{
  "version": 1,
  "ports": {
    "apiPort": 7860,          // phone-facing, 0.0.0.0; replaces PORT_RANGE_START
    "apiPortRangeEnd": 7869,  // replaces PORT_RANGE_END
    "hookPort": 7861          // loopback, secret-gated; replaces HOOK_PORT literal
  },
  "paths": {
    "dataDir": "~/Library/Application Support/cmux-iphone",  // ONE base dir
    "logDir":  "~/Library/Logs/cmux-iphone",
    "sessionTokenFile": "{dataDir}/session-token",   // 0600
    "hookSecretFile":   "{dataDir}/hook-secret",     // 0600
    "cmuxPasswordFile": "{dataDir}/cmux-password"     // 0600 — FOLDED IN from ~/.config/cmux-iphone
  },
  "pairing": {
    "mode": "rotating",       // "rotating" (default) | "fixed"
    "fixedCode": null,        // set only when mode=="fixed" (CMUX_IPHONE_PAIR_CODE)
    "ttlMs": 86400000
  },
  "cmux": {
    "enabled": true,          // setup sets false when cmux absent
    "bin": null,              // CMUX_BIN override; null = auto-discover
    "socketPath": null        // null = read ~/.local/state/cmux/last-socket-path at runtime
  },
  "runner": "cmux"            // "cmux" | "launchd" — chosen at setup (§2)
}
```

Env vars still override config (`PORT`, `CMUX_IPHONE_PAIR_CODE`, `CMUX_BIN`, `CMUX_IPHONE_HOOK_PORT`) — config is the persisted default, env is the runtime override. **The iOS/watchOS clients must stop hardcoding `7860-7869`** (`BonjourDiscovery.swift:78,117`, `WatchBridgeClient.swift:50`, `OnboardingView.swift:115`); they should read the advertised port from the Bonjour TXT record the bridge already publishes (`_cmux-iphone._tcp`). Rename the service type `_cmux-iphone._tcp → _cmux-iphone._tcp` in lockstep on both sides, or keep the old type for v0.1.0 and rename later — but pick one and keep bridge + Swift in sync.

---

## 4. Pre-Release Code Fixes (prioritized, exact)

**P0 — security / correctness blockers (must fix before any public tag):**

1. **Hardcoded pairing code.** `server.js:69` — `const FIXED_PAIRING_CODE = process.env.CMUX_IPHONE_PAIR_CODE || "******";`. Every OSS install ships the well-known code `******`; rate-limiting (`:70-71`, 5/5min) is irrelevant because the value is public in the repo. Because it's truthy, the code never rotates (`pairingCodeExpiresAt = MAX_SAFE_INTEGER`, `:154`) and is never cleared on pair (`:1096 if (!FIXED_PAIRING_CODE)`).
   **Fix:** `const FIXED_PAIRING_CODE = process.env.CMUX_IPHONE_PAIR_CODE || null;`. The `crypto.randomInt` else-branch at `:152` then produces a rotating 6-digit code with the 24h TTL, cleared after pairing. Keep the env override for users who want a fixed code. Wire `pairing.mode/fixedCode` from config.

2. **Over-broad hook remover (data-loss).** `setup-hooks.sh:53-56` strips *any* hook whose URL `startswith('http://127.0.0.1:')` AND contains `'/hooks/'` — across all events. The same predicate runs on **install** dedupe (`:190-195`), so installing cmux-iphone silently deletes a user's unrelated localhost hooks (e.g. `http://127.0.0.1:9000/hooks/foo`). The comment at `:42` claims it scopes to cmux-iphone; the code does not.
   **Fix:** scope to cmux-iphone's exact origin and route set. Match only `f'{HOOK_URL}/hooks/{name}'` for `name in {tool-output, pre-tool-use, session-start, session-end, permission, stop, error}` where `HOOK_URL = http://127.0.0.1:{hookPort}` (the script already knows the port at `:14`). Apply identically to install-dedupe `:190-195`. (When migrated to `lib/hooks.js`, implement once.)

**P1 — private data / reproducibility (must fix before tag):**

3. **Personal path in shipped script.** `run-in-cmux.sh:7` (comment) and `:12` (`NODE="/Users/limseungwon/.local/bin/node"`). Fix per §2.
4. **Local cruft binary candidate.** `cmux.js:38` lists `/Applications/cmux 2.app/...` (a personal duplicate-install artifact). Remove that candidate; keep `cmux.app`, `CMUX_BIN` env (`:33`), and `which` fallback (`:44-47`).
5. **`npm install` → `npm ci`.** `setup.sh:5`, `SKILL.md:25`, `.claude/skills/.../SKILL.md:25`, `README.md:80`, `REMOTE-SETUP.md:15` all use `npm install`, which can drift the committed lockfile. Switch to `npm ci` (fall back to `npm install` only if no lockfile). CLI `setup` does the same.
6. **Stale dependency claim.** `SKILL.md:24` says cmux-iphone "requires the node-pty package." It does not — `package.json` has only `bonjour-service`; server.js uses `script -q /dev/null` + `spawn` (`server.js:340`). Remove the node-pty mention.
7. **Committed `.DS_Store`.** `skill/.DS_Store` is git-tracked (force-added before the ignore rule). `git rm --cached skill/.DS_Store`.

**P2 — config unification (do alongside restructure, §3):**

8. Centralize the three independent definitions of the hook-secret path (`server.js:168`, `setup-hooks.sh:17`, `setup-hooks.sh:233`) into `config.js`.
9. Fold `cmux-password` from `~/.config/cmux-iphone/` (`cmux.js:58`) into the single `dataDir` so all secrets live in one base dir.
10. Replace port literals (`server.js:64-65,167`; `setup-hooks.sh:12,14,231,232`; `install-launchd.sh:27`) with config reads.

**Secret file perms — already correct, keep as invariant:** `hook-secret` `crypto.randomBytes(24)` mode `0600` (`server.js:171-185`); `session-token` `crypto.randomBytes(32)` mode `0600` (`:197-207`); `cmux-password` read-only. Add a `doctor` check that asserts `0600` and re-chmods if drifted.

---

## 5. The `cmux-iphone` CLI

`bin/cmux-iphone.js` dispatches to `commands/<verb>.js`. **Every command is idempotent and safe to re-run.** All read/write the one `config.json`.

| Command | Behavior |
|---|---|
| **`setup`** | Idempotent bootstrap. (1) Preflight: macOS, Node ≥18 (`engines`), warn if cmux/Tailscale absent. (2) Detect Claude/Codex/cmux binaries (reuse server.js `findBinary`). (3) `npm ci` deps. (4) Generate `config.json` if missing (merge, never clobber existing). (5) Generate hook-secret + session-token at `0600` **only if absent** (never rotate on re-run). (6) **Back up** `~/.claude/settings.json` (timestamped) then merge cmux-iphone hooks **scoped** (§4). (7) Choose runner: cmux present → register in-cmux workspace; absent → install LaunchAgent from template. (8) Start the bridge, then **health-check**: `GET /status` returns 200, and if cmux enabled, one cmux RPC succeeds. (9) Print success block (below). Re-running detects existing config/secrets/hooks and reports "already configured (no changes)" per step. |
| **`doctor`** | Read-only diagnostics, **PASS/FAIL block designed to paste into a GitHub issue** (below). No secrets in output — show presence/perms, never values. |
| **`status`** | Live runtime: is bridge up (probe `/status`), which runner, API addr (LAN + Tailscale), cmux mirror on/off, paired devices count, uptime. |
| **`pair`** | Print current pairing code + TTL. `--new` forces rotation (rotating mode). In fixed mode, prints the fixed code and notes it does not expire. |
| **`logs`** | `tail -f` `logDir/bridge.{out,err}.log` (LaunchAgent) or stream the cmux workspace output. `--lines N`, `--follow`. |
| **`restart`** | Runner-aware: LaunchAgent → `launchctl kickstart -k gui/$UID/com.cmuxiphone.bridge`; cmux → restart the workspace (supervisor loop self-heals on process exit). |
| **`uninstall`** | **Surgical.** Remove only cmux-iphone's scoped hooks (§4) from `settings.json` (restore from backup offered); `launchctl bootout` + delete `com.cmuxiphone.bridge.plist`; remove the cmux "Agent Bridge" workspace. `--purge` also deletes `dataDir` (secrets/config) and `logDir`. Default keeps user data. Prints exactly what it removed. |

### `setup` success-output mock

```
✓ cmux-iphone setup complete

  macOS 14.5 · Node v20.11.0 · cmux 0.63.2 detected
  Runner:        in-cmux supervisor (cmux mirror ON)
  API:           http://192.168.1.42:7860        (LAN)
                 http://your-mac.tailnet.ts.net:7860  (Tailscale)
  Hook listener: 127.0.0.1:7861 (secret-gated)
  Pairing code:  408 213   (rotating, expires in 24h)

  Health check:  /status 200 OK · cmux RPC OK · 7 workspaces visible

  Next:
    1. Open the Cmux iPhone app on your iPhone
    2. Enter pairing code  408 213
    3. cmux-iphone doctor   (if anything looks off)
```

### `doctor` PASS/FAIL block (issue-pasteable)

```
cmux-iphone doctor — v0.1.0
─────────────────────────────────────────────
[PASS] macOS               14.5 (Darwin 24.6.0)
[PASS] Node                v20.11.0 (>= 18 required)
[PASS] config.json         present, schema v1
[PASS] hook-secret         present, perms 0600
[PASS] session-token       present, perms 0600
[PASS] Claude Code         /opt/homebrew/bin/claude
[PASS] Claude hooks        7 cmux-iphone hooks installed (scoped)
[WARN] Codex               not found (optional)
[PASS] cmux                0.63.2 (/usr/local/bin/cmux)
[PASS] cmux socket         ~/.local/state/cmux/cmux.sock reachable
[PASS] Runner              in-cmux supervisor (pid 85394)
[PASS] API listener        0.0.0.0:7860  /status 200
[PASS] Hook listener       127.0.0.1:7861
[PASS] Bonjour             advertising _cmux-iphone._tcp
[FAIL] Tailscale           not installed — remote access LAN-only
─────────────────────────────────────────────
Result: 12 PASS · 1 WARN · 1 FAIL
```

---

## 6. Homebrew Packaging

**Tap:** GitHub repo `limseungwon/homebrew-tap` (the `homebrew-` prefix is implicit). Users run `brew install limseungwon/tap/cmux-iphone && brew services start cmux-iphone`. Formula at `Formula/cmux-iphone.rb`.

**Retire `install-launchd.sh` for brew users** — `brew services` generates and manages the LaunchAgent. Do NOT have the formula install its own plist at `brew install` time (fights `brew services`, fails `brew audit`). Keep `install-launchd.sh` only as the non-brew fallback path the CLI uses.

**Two load-bearing facts** (research-confirmed): (a) `package.json` has **no `bin` field**, so `bin.install_symlink libexec.glob("bin/*")` creates nothing → the formula must write its own wrapper (or we add a `bin` field — recommended, see §3); (b) `server.js` is ESM with no shebang, so the wrapper must `exec node server.js`, not exec the file. Because the lone dep is pure JS, **vendoring `node_modules` in the release tarball is safe and arch-independent** — no per-machine compile.

### Formula sketch (vendored, ESM-safe wrapper, service block)

```ruby
class CmuxIphone < Formula
  desc "Bridge Claude Code / cmux sessions to the Cmux iPhone iOS/watchOS app"
  homepage "https://github.com/limseungwon/cmux-iphone"
  url "https://github.com/limseungwon/cmux-iphone/releases/download/v0.1.0/cmux-iphone-v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256"   # CI fills this in
  license "MIT"

  depends_on "node"
  # NOTE: cannot depends_on "cmux" — not a Homebrew package. cmux is an optional
  # runtime dependency; the bridge degrades to hook/phone-only when it is absent.

  def install
    libexec.install Dir["*"]          # vendors bin/, bridge/, node_modules, etc.
    (bin/"cmux-iphone").write <<~SH
      #!/bin/bash
      exec "#{Formula["node"].opt_bin}/node" "#{libexec}/bin/cmux-iphone.js" "$@"
    SH
  end

  service do
    run [opt_bin/"cmux-iphone", "run"]   # "run" = foreground core server for the agent
    keep_alive true                       # == KeepAlive
    # run_type :immediate is default (== RunAtLoad) — omit
    working_dir    libexec
    log_path       "#{Dir.home}/Library/Logs/cmux-iphone/bridge.out.log"
    error_log_path "#{Dir.home}/Library/Logs/cmux-iphone/bridge.err.log"
    environment_variables PATH: std_service_path_env, PORT: "7860"
  end

  test do
    assert_match "cmux-iphone", shell_output("#{bin}/cmux-iphone --help", 0)
  end
end
```

Notes: `brew services start cmux-iphone` (NO `sudo`) gives a user LaunchAgent — required, since cmux is GUI-session-bound; `sudo brew services` makes a system daemon and breaks cmux. The service block only runs the **core** server; the cmux mirror still needs the in-cmux supervisor (§2) — document that `brew services` covers hook/phone, and `cmux-iphone setup` registers the cmux workspace separately. Reboot survival requires the user logged in (agents load on GUI session, same constraint `install-launchd.sh` already documents).

### CI: tag → tarball → sha256 → formula bump

In the **app repo**, `on: release: types: [published]`:

1. **Build the release artifact** — tar *only* the `cmux-iphone/` subtree (not the whole repo with iOS app + `recording.mp4`). Run `npm ci --omit=dev` first if vendoring; attach `cmux-iphone-${tag}.tar.gz` to the release.
2. **Bump the formula** with `mislav/bump-homebrew-formula-action@v6`:

```yaml
- uses: mislav/bump-homebrew-formula-action@v6
  with:
    formula-name: cmux-iphone
    homebrew-tap: limseungwon/homebrew-tap
    download-url: https://github.com/limseungwon/cmux-iphone/releases/download/${{ github.ref_name }}/cmux-iphone-${{ github.ref_name }}.tar.gz
  env:
    COMMITTER_TOKEN: ${{ secrets.COMMITTER_TOKEN }}   # classic PAT, repo + workflow scopes
```

It fetches the asset, computes `sha256`, and rewrites both `url` and `sha256` in the tap (direct push to the tap's default branch for a personal tap). Committing `package-lock.json` + `npm ci` sidesteps brew's `--min-release-age` supply-chain cooldown that could otherwise fail a fresh dep version.

---

## 7. iOS Distribution (honest, free-team reality)

**There is no TestFlight, no public link, no Ad Hoc, no signed IPA.** All are paid Apple Developer Program ($99/yr) features per Apple's membership comparison. A free personal team (S5F357QXBC) gets only on-device dev builds for the developer's own ≤3 devices, expiring every 7 days. Push/APNs is also barred on free teams (already a known blocker). **The owner's "TestFlight public link" milestone is removed.**

### Supported path: build-it-yourself in Xcode (README section)

```
1. git clone https://github.com/limseungwon/cmux-iphone
2. cd ios/ClaudeWatch && xcodegen generate     # project.yml is the source of truth
3. open ClaudeWatch.xcodeproj
4. REQUIRED — change the bundle identifier (this is the #1 fresh-clone blocker):
   In ios/ClaudeWatch/project.yml, replace `com.shobhit.claudewatch`
   (bundleIdPrefix + the two PRODUCT_BUNDLE_IDENTIFIER lines) with YOUR reverse-DNS
   prefix, e.g. com.yourname.cmuxiphone. The watch app id MUST stay
   <iphoneid>.watchkitapp or the Watch app won't pair. Re-run `xcodegen generate`.
5. For BOTH targets (ClaudeWatch iOS + ClaudeWatchWatch): Signing →
   "Automatically manage signing" → select your own Personal Team.
6. Connect iPhone (+ paired Watch) → Product → Run.
7. On device: Settings → General → VPN & Device Management → trust your developer cert.
```

**Warn prominently about the 7-day expiry:** the app stops working one week after the profile is minted — re-run from Xcode to refresh. Mention **SideStore/AltStore** as an optional way to wirelessly auto-refresh the *iPhone* app only (it does not cleanly deliver the watchOS companion — that still needs Xcode/paired-iPhone deploy). State the limits plainly: 3 devices/platform, 10 App IDs/week, **no push notifications** (local notifications only on a free team).

Two app-side fixes that gate a clean clone: the bundle-ID rename must be made **in `project.yml`** (not just the generated `.xcodeproj`, which XcodeGen overwrites), and both targets re-signed in a matched pair.

### "If you enroll ($99/yr)" note
Unlocks TestFlight (100 internal + 10k external testers, public invite links), removes the 7-day expiry (1-year signing), enables APNs/push, and allows Ad Hoc. Frame as an optional upgrade — do **not** build toward it or assume it.

---

## 8. Phased Rollout (corrected, ordered)

**v0.1.0 — must-have (the bridge works, installs cleanly from source, is safe):**

1. **P0 security fixes** — remove hardcoded `******` (`server.js:69`); scope the hook remover + install-dedupe (`setup-hooks.sh:53-56,190-195`). *(blocks any public tag)*
2. **P1 cleanup** — `run-in-cmux.sh` personal path; drop `cmux 2.app`; `npm ci`; remove node-pty doc claim; untrack `.DS_Store`.
3. **Repo restructure → `cmux-iphone/` package** + `config.json` + `config.js` loader; collapse scattered ports/paths.
4. **CLI** — `setup` (idempotent), `doctor` (issue-pasteable), `status`, `pair`, `logs`, `restart`, `uninstall` (surgical). **This is the core deliverable — ship before Homebrew.**
5. **Split topology** — setup chooses cmux-runner vs LaunchAgent; fix `cmux.js` `CMUX_SOCKET_PATH`; reconcile `install-launchd.sh` comment.
6. **Honest docs** — README install-from-source flow, iOS build-it-yourself + bundle-ID rename + 7-day warning; reconcile the two SKILL.md files.
7. **OSS hygiene** — LICENSE (MIT), SECURITY.md, `.gitignore` audit (§9), README essentials.
8. **iOS** — fix `project.yml` bundle ID to a neutral placeholder; make Swift read the port from Bonjour TXT (or document the constraint for v0.1.0).

**v0.2.0 — Homebrew on top (only after CLI is proven by hand):**

9. Personal tap `limseungwon/homebrew-tap` + `Formula/cmux-iphone.rb` (vendored, ESM wrapper, `service do`).
10. CI: release → `cmux-iphone/`-only tarball → `mislav/bump-homebrew-formula-action@v6` formula bump.
11. `brew install limseungwon/tap/cmux-iphone && brew services start cmux-iphone` as the documented one-liner.

**Later / explicitly deferred:**
- Shape B topology (LaunchAgent core + in-cmux RPC proxy).
- ~~TestFlight public link~~ — **removed**; revisit only if owner enrolls in the paid program.
- Submission to homebrew-core (personal tap is sufficient and avoids core's stricter audit/vendoring rules).

**Ordering principle (corrects the owner's plan):** idempotent **CLI setup/doctor/uninstall ships first** and is the thing users run; Homebrew is a packaging convenience layered on top of a CLI that already works standalone. Do not couple the v0.1.0 release to the tap.

---

## 9. Security & Licensing

**Secret file invariants (already correct — enforce in `doctor`/`setup`):**
- `hook-secret` (`randomBytes(24)`), `session-token` (`randomBytes(32)`), `cmux-password` — all mode `0600`, all in `dataDir`. `setup` creates only if absent (never rotates on re-run); `doctor` asserts `0600` and re-chmods on drift.
- Pairing code: rotating 6-digit + 24h TTL by default; fixed only via explicit `CMUX_IPHONE_PAIR_CODE`/config.

**Must NEVER ship / commit:**
- The literal pairing code (fixed at P0).
- Any real `session-token`, `hook-secret`, `cmux-password` — these are runtime-generated and currently *not* git-tracked (verified). Keep it that way.
- The generated `com.cmuxiphone.bridge.plist` (machine-specific absolute paths) — generated into `~/Library/LaunchAgents`, never committed.
- Personal absolute paths (the `run-in-cmux.sh` ones — fixed at P1).

**`.gitignore` (add/verify):**
```
node_modules/
.DS_Store
*.log
# secrets — defense in depth even though they live outside the repo dir
**/session-token
**/hook-secret
**/cmux-password
*.plist.local
```
Untrack the already-committed `skill/.DS_Store`.

**OSS essentials:**
- **LICENSE** — MIT (matches the formula sketch; permissive, expected for a CLI + companion app).
- **SECURITY.md** — report channel (email/issue), the trust model: bridge binds `0.0.0.0:7860` so it is reachable by anyone on the LAN/Tailnet; pairing code + per-device session-token are the auth boundary; hook listener is loopback-only + secret-gated. Advise running over Tailscale rather than exposing the LAN port publicly; note the bridge is **not** designed to face the open internet.
- **README essentials** — what it is; the LAN/Tailnet trust model (one sentence so users don't expose it publicly); install-from-source (and later `brew`); the iOS build-it-yourself + 7-day/no-push caveats; `cmux-iphone doctor` as the first troubleshooting step; cmux is optional (hook/phone works without it).
- **THIRD-PARTY / NOTICE** — single dep `bonjour-service` (MIT) — trivial, but list it.
- Verify the repo's own attribution: `project.yml` and SKILL.md carry a prior author's identifiers (`com.shobhit.claudewatch`, "Claude Watch") — neutralize/reconcile before publishing under the new name.

---

### Relevant files
- `/Users/limseungwon/cmux-iphone/skill/bridge/server.js` (`:69` pairing code, `:64-79,163-168` constants)
- `/Users/limseungwon/cmux-iphone/skill/setup-hooks.sh` (`:53-56,190-195` hook scope; `:227-284` codex-watch heredoc)
- `/Users/limseungwon/cmux-iphone/skill/bridge/run-in-cmux.sh` (`:7,12` personal path)
- `/Users/limseungwon/cmux-iphone/skill/bridge/cmux.js` (`:38,54-70` socket path + cruft)
- `/Users/limseungwon/cmux-iphone/skill/bridge/install-launchd.sh` (misleading cmux claim)
- `/Users/limseungwon/cmux-iphone/ios/ClaudeWatch/project.yml` (`com.shobhit.claudewatch` bundle ID)
- `/Users/limseungwon/cmux-iphone/skill/bridge/package.json` (no `bin` field; `bonjour-service` only)