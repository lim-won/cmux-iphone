# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - Unreleased

### Fixed
- Improved approval alerts so Claude and Codex permission requests are shown more
  reliably in the iPhone app.
- Approval notifications now appear even while the iPhone app is open, so urgent
  requests are harder to miss.
- Codex approval cards are cleared when the request is no longer waiting, keeping
  the approval queue from showing stale items.
- Pairing no longer clears the entered code after connection or IP address errors,
  and the app now offers a quick retry when the code is still valid.
- Manual pairing now works with raw LAN and Tailscale IP addresses.
- Fixed connection failures (App Transport Security error -1022) when pairing by a
  hostname or MagicDNS name instead of a raw IP. `NSAllowsLocalNetworking` was
  silently nullifying `NSAllowsArbitraryLoads`, so plaintext loads to non-`.local`
  hostnames were blocked on both the iPhone and Apple Watch apps.

### Added
- Simplified and Traditional Chinese (简体/繁體) READMEs with a language switcher.

## [0.1.1] - 2026-06-23

### Security
- Hardened the bridge ahead of its public release.
- The local control listener now binds to loopback and is gated by a pair-code,
  with bind-address UX fixes.
- Tightened `.gitignore` and scoped the release token to its CI step only.

### Added
- Tailscale remote-access guide.
- Korean README with an English/한국어 language switcher.
- Homebrew install instructions in the README.

### Changed
- `VERSION` is now the single source of truth, kept in sync across all files.

### Fixed
- README accuracy: watch approvals, ports, default bind address, trademarks, and
  rotating codes.
- License detection.

## [0.1.0] - 2026-06-22

Initial public release.

### Added
- **Bridge** (`skill/bridge`): a local server that connects Claude Code / Codex /
  cmux sessions on your Mac to the Cmux iPhone app over the LAN or Tailscale.
- **Pairing** with per-device, individually revocable bearer tokens; rate-limited
  pairing (5 attempts / 5 minutes). Default is a stable per-machine code; rotating
  codes are opt-in (`cmux-iphone setup --rotating`).
- **Live cmux mirror**: view sessions and type prompts straight into the live
  terminal; fail-closed, screen-hash-guarded approvals for Codex.
- **iPhone + Apple Watch app**: session list, approvals, voice prompts, and a
  Macs switcher for multiple machines. Bearer tokens stored in the Keychain.
- **Runners**: a macOS LaunchAgent (hook/phone/Codex) or an in-cmux supervisor
  (live mirror), chosen automatically by `cmux-iphone setup`.
- **CLI**: `setup`, `status`, `doctor`, `pair`, `restart`, `uninstall`, `logs`.
- **Packaging**: Homebrew formula + tap, and a vendored release tarball.

[0.1.2]: https://github.com/lim-won/cmux-iphone/releases
[0.1.1]: https://github.com/lim-won/cmux-iphone/releases/tag/v0.1.1
[0.1.0]: https://github.com/lim-won/cmux-iphone/releases/tag/v0.1.0
