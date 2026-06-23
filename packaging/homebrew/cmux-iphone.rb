# Homebrew formula for cmux-iphone.
#
# This formula lives in the tap repo (lim-won/homebrew-tap) at
# Formula/cmux-iphone.rb. On the FIRST release, set the real `sha256` (CI bumps
# `url` + `sha256` automatically on every new tag thereafter via
# mislav/bump-homebrew-formula-action). Forkers: replace `lim-won` with your
# own GitHub username in `homepage`/`url` and the tap repo.
#
# Users then:  brew install lim-won/tap/cmux-iphone && cmux-iphone setup
#
# The release tarball is the self-contained bridge package (bridge/ + setup.sh +
# setup-hooks.sh) with node_modules vendored (the only dep, bonjour-service, is
# pure JS, so no per-machine compile).

class CmuxIphone < Formula
  desc "Bridge Claude Code / Codex / cmux sessions to the Cmux iPhone app"
  homepage "https://github.com/lim-won/cmux-iphone"
  url "https://github.com/lim-won/cmux-iphone/releases/download/v0.1.1/cmux-iphone-0.1.1.tar.gz"
  sha256 "161d2a9a2343794dc0b5b857eb2757dd78e9a1fc94aed55e36202521b88bc067" # v0.1.1 (the tap copy is authoritative; bumped per release)
  license "MIT"

  depends_on "node"
  depends_on :macos
  # NOTE: cmux can't be a Homebrew dependency (not a formula). It's an optional
  # RUNTIME dependency — the bridge degrades to hook/phone-only when cmux is absent.

  def install
    # Tarball root contains: bridge/ (with vendored node_modules), setup.sh, setup-hooks.sh
    libexec.install Dir["*"]
    # ESM entrypoint has a shebang but we exec node explicitly so it doesn't
    # depend on `node` being first on the user's PATH.
    (bin/"cmux-iphone").write <<~SH
      #!/bin/bash
      exec "#{Formula["node"].opt_bin}/node" "#{opt_libexec}/bridge/bin/cmux-iphone.js" "$@"
    SH
  end

  # `brew services start cmux-iphone` runs the CORE bridge as a per-user
  # LaunchAgent (hooks + phone API + Codex). The cmux LIVE MIRROR is NOT covered
  # here — a launchd process can't drive the cmux control socket; for that, run
  # `cmux-iphone setup` with cmux present (it registers an in-cmux workspace).
  service do
    run [Formula["node"].opt_bin/"node", opt_libexec/"bridge/server.js"]
    keep_alive true
    working_dir opt_libexec/"bridge"
    log_path "#{Dir.home}/Library/Logs/cmux-iphone/bridge.out.log"
    error_log_path "#{Dir.home}/Library/Logs/cmux-iphone/bridge.err.log"
    environment_variables PATH: std_service_path_env
  end

  def caveats
    <<~EOS
      Next steps:
        cmux-iphone setup     # register Claude hooks + choose runner + print pairing code
        cmux-iphone doctor    # diagnostics

      cmux users: `cmux-iphone setup` runs the bridge inside cmux (live mirror).
      Without cmux you can instead: brew services start cmux-iphone

      After `brew upgrade cmux-iphone`, re-run `cmux-iphone setup` once so the
      LaunchAgent / cmux workspace re-point at the new version.
    EOS
  end

  test do
    assert_match "cmux-iphone", shell_output("#{bin}/cmux-iphone --help")
  end
end
