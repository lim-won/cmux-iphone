# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

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

[0.1.0]: https://github.com/limseungwon/cmux-iphone/releases
