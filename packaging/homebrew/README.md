# Homebrew distribution (one-time setup)

Goal: `brew install OWNER/tap/agent-watch && agent-watch setup`.

The bridge is a pure-JS Node CLI (one dependency, `bonjour-service`), so the
release tarball vendors `node_modules` — no per-machine compile. `OWNER` is your
GitHub username.

## 1. Create the tap repo

Create a public repo named **`homebrew-tap`** under your account (the
`homebrew-` prefix is what makes `OWNER/tap` work). Add the formula:

```
homebrew-tap/
└── Formula/
    └── agent-watch.rb     # copy of packaging/homebrew/agent-watch.rb
```

Edit `agent-watch.rb`: replace every `OWNER` with your GitHub username. Leave
`sha256` as the placeholder for now (the first real release fills it).

## 2. Add the bump token

The release workflow needs to push the updated formula to your tap:

1. Create a **classic Personal Access Token** with `repo` + `workflow` scope.
2. In THIS repo: Settings → Secrets and variables → Actions → add
   `COMMITTER_TOKEN` = that PAT.

(`.github/workflows/release.yml` resolves the tap as
`${{ github.repository_owner }}/homebrew-tap` and the asset URL from the release.)

## 3. Cut a release

```bash
git tag v0.1.0 && git push origin v0.1.0
# then publish a GitHub Release for that tag (gh release create v0.1.0 --generate-notes)
```

On publish, the workflow:
1. builds `agent-watch-0.1.0.tar.gz` (the `bridge/` + `setup.sh` + `setup-hooks.sh`
   with vendored prod deps),
2. attaches it to the release,
3. rewrites `url` + `sha256` in `OWNER/homebrew-tap/Formula/agent-watch.rb`.

For the **first** release, the formula's placeholder `sha256` is wrong until the
bump runs — if `brew install` is attempted before the first successful bump,
fill the sha by hand once: `shasum -a 256 agent-watch-0.1.0.tar.gz`.

## 4. Install

```bash
brew install OWNER/tap/agent-watch
agent-watch setup
```

`brew services start agent-watch` runs the **core** bridge (hooks + phone) as a
LaunchAgent. The cmux **live mirror** needs the in-cmux runner — let
`agent-watch setup` handle that when cmux is present (a launchd process can't
reach the cmux control socket). See the main README for the topology.

## Updating

Tag + release a new version; the workflow re-bumps the formula. Users get it via
`brew update && brew upgrade agent-watch`.

## Notes / limits

- Pin the action versions (`mislav/bump-homebrew-formula-action`,
  `softprops/action-gh-release`) to current majors before relying on this.
- This is a personal tap, not homebrew-core (which has stricter audit/vendoring
  rules and a review queue) — a tap is the right choice here.
- Reboot survival for the LaunchAgent requires the user to be logged in
  (auto-login for headless Macs).
