# Homebrew formula for agent-watch.
#
# This is the TEMPLATE that lives in your tap repo (OWNER/homebrew-tap) at
# Formula/agent-watch.rb. Replace OWNER with your GitHub username. After the
# first release, the GitHub Action (mislav/bump-homebrew-formula-action) rewrites
# `url` + `sha256` automatically on every new tag — you only edit OWNER once.
#
# Users then:  brew install OWNER/tap/agent-watch && agent-watch setup
#
# The release tarball is the self-contained bridge package (bridge/ + setup.sh +
# setup-hooks.sh) with node_modules vendored (the only dep, bonjour-service, is
# pure JS, so no per-machine compile).

class AgentWatch < Formula
  desc "Bridge Claude Code / Codex / cmux sessions to the Agent Watch iPhone app"
  homepage "https://github.com/OWNER/agent-watch"
  url "https://github.com/OWNER/agent-watch/releases/download/v0.1.0/agent-watch-0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # set on first release; CI bumps after
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
    (bin/"agent-watch").write <<~SH
      #!/bin/bash
      exec "#{Formula["node"].opt_bin}/node" "#{opt_libexec}/bridge/bin/agent-watch.js" "$@"
    SH
  end

  # `brew services start agent-watch` runs the CORE bridge as a per-user
  # LaunchAgent (hooks + phone API + Codex). The cmux LIVE MIRROR is NOT covered
  # here — a launchd process can't drive the cmux control socket; for that, run
  # `agent-watch setup` with cmux present (it registers an in-cmux workspace).
  service do
    run [Formula["node"].opt_bin/"node", opt_libexec/"bridge/server.js"]
    keep_alive true
    working_dir opt_libexec/"bridge"
    log_path "#{Dir.home}/Library/Logs/claude-watch/bridge.out.log"
    error_log_path "#{Dir.home}/Library/Logs/claude-watch/bridge.err.log"
    environment_variables PATH: std_service_path_env
  end

  def caveats
    <<~EOS
      Next steps:
        agent-watch setup     # register Claude hooks + choose runner + print pairing code
        agent-watch doctor    # diagnostics

      cmux users: `agent-watch setup` runs the bridge inside cmux (live mirror).
      Without cmux you can instead: brew services start agent-watch
    EOS
  end

  test do
    assert_match "agent-watch", shell_output("#{bin}/agent-watch --help")
  end
end
