# Contributing to Cmux iPhone

Thanks for your interest in contributing to **Cmux iPhone**! This project has two
parts: a Node **bridge** (`skill/bridge`) and an **iOS/watchOS app** (`ios/`). You
can contribute to either independently.

## Prerequisites

- **macOS** (the bridge and app are macOS/Apple-platform tools).
- **Node 18+** — for the bridge.
- **Xcode** + **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — only if you work
  on the app. XcodeGen is a maintainer tool used to regenerate the project from
  `project.yml`; the committed `.xcodeproj` is usable without it.

## Developing the bridge

```sh
cd skill/bridge
npm ci
npm test
```

`npm test` runs the **14 unit tests** via `node --test`. They are fast, pure, and
have no external dependencies.

Integration tests are gated behind `CW_INTEGRATION=1` and require a **live local
cmux instance plus valid device tokens**, so they are **not run in CI**. To run
them locally:

```sh
npm run test:integration
```

## Building the app

```sh
cd ios/CmuxiPhone
xcodegen generate          # only if you changed project.yml
open CmuxiPhone.xcodeproj
```

Each contributor signs with their **own** identity:

- Set your bundle id once with `scripts/configure-ios.sh com.yourname.cmuxiphone`.
- Set your **DEVELOPMENT_TEAM** on both targets in Xcode (Signing & Capabilities).

**Do NOT commit your personal signing identity or Team id.** Keep those changes
local; they should never appear in a PR.

## Pull request flow

1. Branch from `main`.
2. Keep changes **focused** — one logical change per PR.
3. Ensure `npm test` passes (run it for any bridge change).
4. Update docs if behavior changes.
5. Describe **what** changed and **why** in the PR description.

See [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md) for the
checklist.

## Releasing / version bumps

`VERSION` (repo root) is the **single source of truth** for the release version.
To bump it, edit `VERSION`, then stamp every file that carries a version:

```sh
node scripts/sync-version.mjs          # writes VERSION into package.json, SKILL.md, Info.plist, …
node scripts/sync-version.mjs --check   # CI runs this; fails if anything drifts
```

The Homebrew tarball/formula version is derived from the git tag at release time.

## Reporting security issues

**Do not open a public issue for security problems.** Report them privately — see
[`SECURITY.md`](SECURITY.md) (GitHub private Security Advisories). This protects
users until a fix is available.

## Code style

Match the surrounding code. There is no separate formatter step — follow the
conventions already present in the file you are editing.
