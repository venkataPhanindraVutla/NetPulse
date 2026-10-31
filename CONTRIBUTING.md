# Contributing and setup guide

This guide gets you from a fresh clone to a running app, a passing test suite and a working copy of the website. It also covers how releases are made. Bug reports and pull requests are welcome.

If you use an AI coding agent, it should read [AGENTS.md](AGENTS.md); the rules there apply to people too.

## Requirements

| For | You need |
| --- | --- |
| The app | macOS 14 or later, Xcode with Swift 6 (developed and tested with Xcode 27.1), [Homebrew](https://brew.sh) |
| Generating the Xcode project | [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen` |
| The website | Node.js 22 or later; `engines` in `site/package.json` has the exact minimum (developed with Node 24) |
| Releases | The GitHub CLI: `brew install gh` |

## Repository layout

| Path | What's there |
| --- | --- |
| `Sources/NetPulseCore/` | All measurement and storage logic, as a Swift package with no UI: interface counters, the nettop supervisor and parser, network identity, usage accounting, caps, SQLite storage. |
| `Sources/netpulse-probe/` | A command-line harness around the same engine, used for measurements. |
| `Tests/NetPulseCoreTests/` | Tests for the core package, with a captured nettop fixture. |
| `App/` | The macOS app: SwiftUI popover, AppKit menu bar item, settings, notifications, login item. `App/Debug/` holds debug-only probes. |
| `project.yml` | The app target definition. `NetPulse.xcodeproj` is generated from it and is not committed. |
| `Config/` | Signing settings. `Local.xcconfig` is yours and git-ignored. |
| `scripts/make-dmg.sh` | Builds the release DMG. |
| `site/` | The website (Astro), deployed to GitHub Pages. |
| `docs/` | Images for the README, plus the original design spec, plan and measurement notes. |

## 1. Build and run the app

```sh
git clone https://github.com/venkataPhanindraVutla/NetPulse.git
cd NetPulse
xcodegen generate
open NetPulse.xcodeproj
```

Run the `NetPulse` scheme. The app has no Dock icon; look for it in the menu bar. If it doesn't appear, see "If you can't see the menu bar item" in the [README](README.md#if-you-cant-see-the-menu-bar-item).

From the command line instead:

```sh
xcodebuild -project NetPulse.xcodeproj -scheme NetPulse -configuration Debug \
  -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/NetPulse.app
```

Run `xcodegen generate` again whenever you add or remove files under `App/` or change `project.yml`.

### Signing

Without any setup the app is signed ad hoc ("Sign to Run Locally"). That's enough to run it, but an ad hoc signature has no stable identity, so macOS may ask for Location and Notifications again after each rebuild.

To keep permissions across rebuilds, sign with your own certificate:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# set DEVELOPMENT_TEAM to your team ID: security find-identity -v -p codesigning
```

`Config/Local.xcconfig` is git-ignored. Never commit it, and never put a team ID anywhere else in the repo.

## 2. Run the tests

```sh
swift test
```

This builds `NetPulseCore` and runs the full suite (162 tests at the time of writing) in a few seconds, with no app or Xcode project needed. A couple of tests start a real `nettop` briefly.

Changes under `App/` aren't covered by `swift test`. Build the app target as well (step 1) to check they compile.

## 3. Measure with netpulse-probe

`netpulse-probe` runs the same engine without the app. It's how the accuracy and CPU figures in the README were measured.

```sh
swift build -c release
.build/release/netpulse-probe --seconds 60                  # sample and print a summary
.build/release/netpulse-probe --seconds 600 --db /tmp/p.sqlite --nettop-interval 5
.build/release/netpulse-probe --network                     # print the detected network
```

## 4. The debug harness

Debug builds accept launch arguments that drive the app for testing and screenshots. They're compiled out of Release builds (`#if DEBUG`). Set them in Xcode under Product › Scheme › Edit Scheme › Arguments, or pass them after `--args` with `open`.

| Argument | What it does |
| --- | --- |
| `--render-popover <dir>` | Renders the popover tabs with sample data into PNGs in `<dir>`. The README screenshots come from this. |
| `--probe-tabs <dir>` | Opens the real popover and screenshots each tab in turn. |
| `--open-settings`, `--open-settings=networks` | Opens Settings on the General or Networks pane. |
| `--test-cap-alert` | Posts a sample cap notification. |
| `--debug-pause`, `--debug-resume` | Pauses or resumes monitoring. |
| `--simulate-sleep-wake` | Runs the sleep and wake handling without sleeping the Mac. |
| `--probe-status-item` | Opens the popover from the menu bar item and logs where it appeared. |
| `--probe-refresh` | Prints the current usage figures to stdout after a few seconds, then quits. |

The real data lives in `~/Library/Application Support/NetPulse/usage.sqlite`. To start fresh, quit the app, delete that folder and run `defaults delete io.github.netpulse.NetPulse`.

## 5. Work on the website

```sh
cd site
npm ci
npm run dev        # http://localhost:4321/NetPulse/
npm run build      # static output in site/dist
```

- Pages are in `site/src/pages/`: `index.astro` is the landing page, and `privacy.md` and `terms.md` are the legal pages.
- `site/src/config.ts` holds the version number and every shared link (download, repository, Buy Me a Coffee).
- `site/src/layouts/Base.astro` holds the metadata, navigation and footer for every page.
- Fonts are self-hosted through Astro's fonts API, and the site loads no third-party scripts. Keep it that way: the privacy policy promises it.
- A push to `main` that touches `site/` deploys the site through `.github/workflows/deploy-site.yml`.

## 6. Make a release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`, and `version` in `site/src/config.ts`.
2. Build the DMG:

   ```sh
   ./scripts/make-dmg.sh
   ```

   It builds a Release app signed ad hoc (signing is overridden on the command line, so your `Local.xcconfig` team never ends up in a release), wraps it in `dist/NetPulse-<version>.dmg` with an Applications shortcut, verifies the image and prints its SHA-256.
3. Test the DMG: open it, drag NetPulse into Applications, launch it with right-click › Open, and check the menu bar item and all three tabs.
4. Publish it:

   ```sh
   gh release create v<version> dist/NetPulse-<version>.dmg --title "NetPulse <version>" --notes "…"
   ```

5. Commit the version bump and push to `main`, which redeploys the website with the new download link.

Releases aren't notarized yet, which needs a paid Apple Developer account. Until then, the install notes in the README and on the website must keep the right-click › Open step.

## Guidelines

- **Privacy is the product.** The app makes no network connections and collects nothing. Don't add analytics, crash reporting, update checks or anything else that phones home.
- **Keep it light.** The app and its nettop child target about 1% CPU in total. If you change sampling, parsing or rendering, measure again (see the README's CPU section) and include the numbers in your pull request.
- **Keep the numbers honest.** Per-app totals plus "Other / system" must add up to the interface total. Show gaps instead of guessing.
- **Core logic belongs in `NetPulseCore`, with tests.** The app target should stay a thin UI layer.
- **No personal identifiers in commits.** That includes team IDs, signing identities, Wi-Fi names, MAC addresses, email addresses and local paths, in code, docs, screenshots and fixtures.
- **Commit messages** follow the existing style: `feat(app): …`, `fix(site): …`, `docs: …`, with a short body explaining why.

Before opening a pull request, run `swift test`, build the app if you touched `App/`, and run `npm run build` if you touched `site/`.
