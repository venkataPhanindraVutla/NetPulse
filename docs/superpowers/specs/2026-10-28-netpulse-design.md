# NetPulse: design

Date: 2026-10-28 · Status: draft for approval

## Intent

NetPulse is a native macOS menu bar app that answers three questions at a glance:

1. **"Is the network slow, or is it me?"** Live ↓/↑ speed in the menu bar, refreshed about every second.
2. **"Which app ate my data?"** Per-app download/upload totals for today, this week and this month.
3. **"Am I staying under my cap?"** Per-network monthly (and daily) totals against optional caps, with a notification when a cap is crossed.

The owner builds it for themselves first and publishes it as open source on GitHub. It's local-first: no account, no cloud, no telemetry, and no outbound network calls of its own.

The starting point is the "NetPulse MVP specification" the owner shared, which covers live speed, interface counters, SQLite, `MenuBarExtra`, `SMAppService` and notifications. This design keeps that spec and makes three changes: **per-app usage**, **per-network usage and caps**, and the **UI layout** below. Where this document and that spec disagree, this document wins.

## Goals

- Live download and upload speed in the menu bar.
- Per-app usage (↓, ↑, total) for Today / Week / Month, filterable by network.
- Per-network usage and caps. Each network can have its own daily and/or monthly cap. "All networks" sums them.
- History: daily bars for a month, plus totals for today, week, month and last month.
- Optional caps with notifications at 80% and 100%, each sent once per period.
- Starts at login (user can turn it off), and pause/resume.
- Usage survives restarts, crashes (losing at most about 30 s) and sleep/wake.

## Non-goals (MVP)

- Blocking, throttling or firewalling apps.
- Per-website or per-domain breakdown.
- Syncing across Macs, or iOS.
- Mac App Store distribution. The sandbox blocks per-process network data, so distribution is direct only.
- Counting traffic while the app isn't running. The app says plainly when data is missing.

## Anti-goals (failures even if it technically works)

The owner named all four:

1. **Battery or CPU drain.** Any noticeable fan, heat or battery cost is a failure. Budget: **under 1% average CPU** for NetPulse plus any helper process, measured on this Mac during idle browsing. This must be verified, not assumed.
2. **Numbers that can't be trusted.** Totals must never go negative, double-count, or jump. Per-app numbers must add up to the network total, with the remainder shown as "Other / system". Labels say "device traffic", not ISP-billed usage.
3. **Nagging.** At most one alert per threshold per period. Permission prompts are asked once, in context, never on a loop.
4. **A cluttered menu bar.** The default label is compact (stacked); see UI.

## Constraints

- Swift 6, SwiftUI with AppKit where needed. Built and run on macOS 26.6 / Apple Silicon with Xcode 27.1.
- Not sandboxed (required for per-process data). Hardened runtime on.
- No third-party runtime dependencies. SQLite comes from the system `libsqlite3`.
- Decimal units by default (1 GB = 10⁹ bytes). A setting switches rates to Mbps.

## How it works (decided)

### Data sources

| What | Source | Cadence |
|---|---|---|
| Interface totals (live speed + network totals) | `sysctl` `NET_RT_IFLIST2` → `if_data64` (64-bit counters). **Not** `getifaddrs` `if_data`, whose 32-bit counters wrap at 4 GB. | 1 s |
| Per-app bytes | `/usr/bin/nettop` run as one long-lived child process in CSV logging mode (`-P -L 0 -x -s 5 -J bytes_in,bytes_out`, plus `-t` filters as needed). Verified on this Mac: works without admin rights. | 5 s |
| Current network | Primary interface via `SCDynamicStore`/`NWPathMonitor`. Wi-Fi name via CoreWLAN, which needs Location permission. Router fingerprint = gateway MAC from the ARP table. | on change |

Rules:
- Exclude loopback. Don't sum virtual interfaces (`utun*`, `bridge*`, `awdl*`, `llw*`, `ap*`, `anpi*`) on top of physical ones. VPN traffic is counted once, on the physical interface it leaves through.
- **Accounting:** take per-interface deltas. If a counter drops, the interface disappears, or the Mac wakes from sleep, start a new baseline and record a gap instead of a negative or bogus delta.
- **Per-app grouping:** a process ID maps to its executable path (`proc_pidpath`), then to the enclosing `.app` bundle (bundle ID, display name, icon). Helpers roll up to the parent app (all Chrome helpers become "Google Chrome"). XPC services such as `com.apple.WebKit.Networking` are assigned to the **responsible** app (Safari, Mail…) using the responsible-PID lookup. That's a private API, so if it fails the traffic falls back to an "Apple WebKit" bucket rather than a guess. Non-app processes (`mDNSResponder`, `softwareupdated`…) appear under their process name, grouped under "System".
- **Per-app per-network:** each per-app delta is assigned to the network that was primary during that 5 s window.
- **Other / system** = network interface delta − sum of attributed app deltas, floored at 0. This bucket is always shown so the totals add up visibly.

### Networks

- Each network gets a stable ID. Wi-Fi uses the network name if Location is granted, otherwise the router fingerprint. Ethernet is one entry per adapter (by hardware address).
- **Location permission** is asked once, at first run, with a one-line explanation ("to show Wi-Fi network names; NetPulse never stores or sends your location"). If it's declined, the app uses the router fingerprint and shows a "New network detected. Name it?" prompt in the popover, not a notification. The user can rename any network.
- Caps reset on the 1st by default, with a per-network billing day setting (1–28).

### Storage (SQLite, system libsqlite3)

- `networks(id, kind, display_name, fingerprint, ssid?, billing_day)`
- `apps(id, bundle_id?, process_name, display_name, group)`
- `usage(bucket_start_utc, network_id, app_id NULLABLE, down_bytes, up_bytes)`. `app_id` NULL means the network total row. Primary key `(bucket_start_utc, network_id, app_id)`; writes are upserts that add to the existing row.
- **15-minute buckets in UTC.** These line up with every real timezone offset, including India's +5:30, so local day, week and month boundaries are always exact. Totals are aggregated at query time in the user's current timezone.
- `caps(network_id, period, limit_bytes, enabled, last_alert_period, last_alert_threshold)`
- `gaps(start_utc, end_utc, reason)`, used to show "data incomplete" on affected days.
- Deltas are kept in memory and flushed in one transaction every 30 s and on quit. Raw cumulative snapshots are not stored long-term.
- No retention limit in the MVP: 15-minute buckets with roughly 50 apps come to a few MB a year.

### Concurrency

Sampling, `nettop` parsing and SQLite run off the main actor (a sampling actor plus a storage actor). The UI is an `@Observable` model on `@MainActor`, updated at most once per second.

### Power and CPU

- Interface sampling uses a 1 s timer with leeway. When the popover is closed **and** the menu bar label is set to icon-only, the interval drops to 5 s.
- `nettop` stays at 5 s. On sleep it's suspended (SIGSTOP) or stopped, and on wake it's restarted with a fresh baseline.
- Measure CPU with Activity Monitor/`top` over 10 minutes and record the result in the README. If the 1% budget is blown, cut the `nettop` cadence before cutting features.

## UI (decided with mockups)

- **Menu bar label:** a setting. The default is **stacked** (two small lines, ↑ on top, ↓ below). Other options: single line `↓ 8.4 MB/s ↑ 1.2 MB/s`, download-only, icon-only. When paused, the label shows a paused state.
- **Popover** (`MenuBarExtra`, `.window` style, about 320 pt wide) with three tabs in a segmented control:
  - **Now:** live ↓/↑ with the current network name; today's ↓/↑ totals; this month's progress against the current network's cap (with "N days left · ~X GB/day"); the top 3 apps today with an "All apps ›" link to the Apps tab.
  - **Apps:** a Today / Week / Month switch and a network picker (All networks / each network); a ranked list with app icon, name, ↓/↑ values and a split download/upload bar; "Other / system" always listed last.
  - **History:** month navigation ‹ › and a network picker; daily bar chart (Swift Charts) with the cap pace line; totals for today, this week, this month and last month. Days with gaps are marked.
  - **Footer:** monitoring status dot, pause/resume, settings, quit.
- **Settings window:** menu bar label style, units (MB/s vs Mbps), launch at login, networks (rename, billing day, daily/monthly caps), notifications on/off, a "data incomplete" explanation.
- Visual style: clean, native and minimal, with subtle motion only. Mockups are kept in `.superpowers/brainstorm/`.

## Project setup

- Location: `~/Documents/Zoom/NetPulse`, new git repo.
- Swift Package `NetPulseCore` (counters, `nettop` parser, process-to-app resolver, accounting, aggregation, storage). Tests run with `swift test`, with no app needed.
- A macOS app target `NetPulse` (`LSUIElement`, no Dock icon), generated with **xcodegen** from `project.yml`, so the repo carries no hand-edited `.pbxproj`.
- Minimum macOS **14.0**, for `@Observable`, newer Swift Charts and SMAppService behavior. The spec said 13; this is raised.
- **Signing (owner's decision):** local builds are signed with the owner's free Apple ID Personal Team ("Apple Development"), so permissions survive rebuilds. The owner adds their Apple ID in Xcode → Settings → Accounts. Paid Developer ID and notarization for GitHub releases come later, as a separate step. The team ID lives in a git-ignored `Local.xcconfig`, so the open-source repo doesn't hard-code anyone's team.
- MIT license. The README covers what's measured, known limits, the permission reasons and how to build.

## Testing focus

Unit tests (no network needed):
- Counter delta and baseline logic: counter reset, interface disappearance, sleep gap, no negative deltas.
- Speed calculation with uneven intervals.
- `nettop` CSV parser against captured real output (including names with spaces and dots, such as `Google Chrome H.1135`).
- Process-to-app grouping (helper paths, XPC services, non-app daemons).
- Aggregation boundaries: local day, week and month in UTC+5:30, a DST-observing zone, and a billing day of 15.
- Cap alerts fire once per threshold per period.

Manual checks on the real Mac: a 1 GB download compared against the network total; the sum of per-app numbers plus Other equals the total; Wi-Fi ↔ hotspot switch; VPN on; sleep/wake; force-quit then relaunch; the CPU budget.

## Settled after builder review (Claude's calls)

- **Multiple active networks.** By default one `nettop` runs and app traffic goes to the primary network. When more than one physical interface carries traffic at the same time (for example Wi-Fi plus Ethernet), the sampler switches to one `nettop` per interface type (`-t wifi`, `-t wired`), so per-network app sums stay honest. VPN (`utun*`) traffic is credited to the physical network underneath.
- **CPU gate early, not last.** CPU is measured as soon as the samplers run, before any UI work. The `nettop` cadence is an internal setting (5 s default, 15 s floor). If 15 s still breaks the 1% budget, stop and report back instead of shipping.
- **`nettop` supervision.** If it exits or goes silent for more than 3 intervals, it is restarted with backoff (1 s, 5 s, 30 s, then every 60 s), a `gaps` row is recorded, and attribution for that window goes to Other / system.
- **Notifications.** Use `UNUserNotificationCenter`. Permission is requested only when the user first enables a cap. If notifications are denied or unavailable, the cap state still shows in the popover (progress bar turns amber at 80% and red at 100%) and the Settings screen says notifications are off.
- **Caps.** Caps apply to network totals only (no per-app caps in the MVP). A daily cap uses the local calendar day. A monthly cap uses the network's billing day.
- **Other / system.** Calculated per network. "All networks" sums the per-network remainders.
- **Verification spike first.** Before building, do a short spike on this Mac to confirm `nettop` stream behavior, the responsible-PID lookup, CoreWLAN with Location from an `LSUIElement` app, and `MenuBarExtra(.window)` on macOS 26.

## Left to the builder

- The exact `nettop` flags. Confirm whether `-d` (delta) or cumulative-per-PID mode gives cleaner deltas, and how PID reuse and process exit appear in the stream.
- Whether one `nettop` per interface type (`-t wifi`, `-t wired`) is needed to attribute per-app traffic correctly when Wi-Fi and Ethernet are both up. The default is the primary-network assignment described above.
- Internal type and module names, SQLite wrapper shape, app icon (simple, monochrome menu bar template image).
- Signing and notarization of GitHub releases. Not needed for the owner's local builds; plan it as a final, separate step.

## Calls made by Claude (not explicitly decided by the owner)

- `NET_RT_IFLIST2` instead of `getifaddrs` (32-bit wrap).
- 15-minute UTC buckets.
- Assigning per-app traffic to the primary network.
- Alert thresholds at 80% and 100%.
- Billing-day setting.
- Minimum macOS 14.
- xcodegen + a separate core package.
- MIT license.
- No retention limit.
- Responsible-PID lookup for XPC services, with an honest fallback bucket.
