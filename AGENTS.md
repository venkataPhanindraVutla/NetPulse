# AGENTS.md

Instructions for AI coding agents working in this repository. Humans: [CONTRIBUTING.md](CONTRIBUTING.md) has the same setup with more explanation.

## What this is

NetPulse is a native macOS 14+ menu bar app (Swift 6, SwiftUI + AppKit) that shows live network speed and data usage per app and per network, with optional caps. It's free and MIT-licensed, distributed as an ad hoc signed DMG on GitHub Releases, and isn't sandboxed because it runs `/usr/bin/nettop`. The website in `site/` is Astro, deployed to GitHub Pages.

## Hard rules

- **No network access from the app.** No URLSession, analytics, crash reporting or update checks. "Makes no network connections" is a public promise in the README, the website and the privacy policy.
- **No personal identifiers in the repo**: team IDs, signing identities, Wi-Fi names, MAC addresses, email addresses or absolute local paths, in code, docs, fixtures or screenshots. `Config/Local.xcconfig` is git-ignored; never commit it or copy its values elsewhere.
- **Don't edit `NetPulse.xcodeproj`.** It is generated from `project.yml` by `xcodegen generate` and is git-ignored.
- **Release DMGs come from `scripts/make-dmg.sh` only.** It forces ad hoc signing so no team ID is embedded.
- **Debug-only code stays inside `#if DEBUG`.** That covers everything in `App/Debug/` and the launch-argument hooks in `App/NetPulseApp.swift`.
- **Don't change sampling cadence (1 s interface counters, 10 s nettop) without measuring CPU.** The budget is about 1% for the app plus nettop.
- **Per-app numbers plus "Other / system" must equal the interface total.** Mark gaps instead of guessing.
- Ask before anything outward-facing: pushing, creating releases, editing the GitHub repository settings, or posting anywhere.

## Map

| Path | Contents |
| --- | --- |
| `Sources/NetPulseCore/Counters/` | sysctl `NET_RT_IFLIST2` interface counters |
| `Sources/NetPulseCore/Apps/` | nettop process supervisor (pty, restarts), CSV parser, PID → app bundle resolution |
| `Sources/NetPulseCore/Networks/` | Network detection and identity (SSID, gateway MAC, Ethernet adapter MAC) |
| `Sources/NetPulseCore/Accounting/` | Counter deltas, speed, usage accumulation |
| `Sources/NetPulseCore/Engine/MonitorEngine.swift` | The central loop that ties it all together |
| `Sources/NetPulseCore/Storage/` | Hand-written SQLite wrapper and `UsageStore` (schema versioned with `PRAGMA user_version`) |
| `Sources/NetPulseCore/Caps/`, `Periods/` | Cap evaluation, day/week/month and billing-period boundaries |
| `App/AppModel.swift` | UI state, cap evaluation and notifications glue |
| `App/MenuBar/`, `App/Popover/`, `App/Settings/`, `App/Services/` | Menu bar item, popover tabs, settings, system services |
| `site/src/config.ts` | Version and all shared links for the website |
| `site/src/layouts/Base.astro` | Metadata, navigation and footer for every page |
| `site/src/pages/` | `index.astro`, `privacy.md`, `terms.md` |

## Commands

Run from the repository root unless noted.

| Task | Command | Expected |
| --- | --- | --- |
| Core tests | `swift test` | All pass (162 at the time of writing), a few seconds |
| Generate Xcode project | `xcodegen generate` | Writes `NetPulse.xcodeproj` |
| Build the app | `xcodebuild -project NetPulse.xcodeproj -scheme NetPulse -configuration Debug -derivedDataPath .build/xcode build -quiet` | Exit 0, no warnings from our sources |
| Engine harness | `swift build -c release && .build/release/netpulse-probe --seconds 60` | Prints a usage summary |
| Release DMG | `./scripts/make-dmg.sh` | `dist/NetPulse-<version>.dmg`, ad hoc, verified |
| Website | `cd site && npm ci && npm run build` | 3 pages plus `sitemap-index.xml` in `site/dist` |
| Website dev server | `cd site && npm run dev` | http://localhost:4321/NetPulse/ |

## Before you say a change is done

1. `swift test` passes.
2. If you touched `App/` or `project.yml`: `xcodegen generate`, then build the app target. `swift test` doesn't compile the app.
3. If you touched `site/`: `npm run build` succeeds. For visual changes, check the page at desktop and phone widths, with no horizontal scroll.
4. If you changed a user-visible fact (requirements, permissions, what's stored, install steps), update the README, `site/src/pages/privacy.md` or `terms.md`, and the landing page to match.

## Conventions

- Swift 6 language mode with strict concurrency. Shared mutable state lives in actors; UI state is `@MainActor`.
- New measurement or storage logic goes in `NetPulseCore`, with tests in `Tests/NetPulseCoreTests`. Keep the app target a thin UI layer.
- Schema changes go through a new `PRAGMA user_version` migration in `UsageStore`, never by editing the v1 schema.
- Units are decimal (1 GB = 10⁹ bytes). Use `ByteFormatter`.
- Logs use `os.Logger` and must not include Wi-Fi names or MAC addresses.
- Website: no third-party scripts, cookies or analytics, and fonts are self-hosted. The privacy policy depends on this.
- Commits: `feat(app): …`, `fix(core): …`, `feat(site): …`, `docs: …`, with a body that explains why.

## Gotchas

- On macOS 26, a new menu bar item can be registered but hidden behind the notch. "I can't see it" usually isn't a bug; see the README.
- Ad hoc builds lose Location and Notification permission on every rebuild. Use `Config/Local.xcconfig` with your own team for day-to-day work.
- nettop's per-socket bytes exclude TCP/IP overhead, so outbound "Other / system" is large while downloading. That's expected.
- The website is served under `/NetPulse/`. Build links from `base` in `site/src/config.ts`, never from absolute `/` paths.
- `dist/` is git-ignored. It holds local DMGs and the Reddit drafts.
- `site/AGENTS.md` is the stock Astro template note. This file takes precedence.
