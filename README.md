# NetPulse

NetPulse is a native macOS menu bar app that shows live network speed and how much traffic this Mac has used, per app, per network and over time. It runs entirely on your Mac: no telemetry, no accounts, no network calls of its own.

**Website:** https://venkataphanindravutla.github.io/NetPulse/ · **Download:** [latest release](https://github.com/venkataPhanindraVutla/NetPulse/releases/latest) · **Free and MIT licensed**

[![NetPulse demo: live speed in the menu bar, apps ranked by usage, and per-network totals with a cap alert](docs/images/demo.gif)](https://venkataphanindravutla.github.io/NetPulse/media/netpulse-demo.mp4)

<sub>A 10-second demo with simulated data. Click it for the full-quality video.</sub>

## Features

- Live download and upload speed in the menu bar (stacked, single line, download-only or icon-only).
- Per-app usage for today, this week and this month. Helper processes roll up under their app, so Chrome's helpers count as "Google Chrome".
- Per-network totals, so home Wi-Fi, a phone hotspot and office Ethernet are tracked separately.
- Optional daily and monthly caps per network, with one notification at 80% and one at 100%.
- A daily history chart for each month. Days when NetPulse wasn't running or was paused are marked, not guessed.
- An "Other / system" row, so the per-app numbers always add up to the interface total.

<p>
  <img src="docs/images/now-light.png" alt="Now tab" width="260">
  <img src="docs/images/apps-dark.png" alt="Apps tab, dark appearance" width="260">
  <img src="docs/images/history-light.png" alt="History tab" width="260">
</p>

<img src="docs/images/menubar-labels.png" alt="Paused icon and two stacked menu bar labels" width="420">

The screenshots are rendered with sample data by the app's debug harness, not captured from a real session. The last image shows the paused icon and two stacked label styles.

## Install

1. Download `NetPulse-0.1.0.dmg` from the [latest release](https://github.com/venkataPhanindraVutla/NetPulse/releases/latest) and drag NetPulse into Applications.
2. The build is signed ad hoc and not notarized yet. The first time, right-click NetPulse in Applications and choose **Open**, or click **Open Anyway** in System Settings › Privacy & Security.
3. Look for it in the menu bar. It has no Dock icon.

The release needs **macOS 14 or later on Apple Silicon**. Intel Macs are untested.

### If you can't see the menu bar item

On macOS 26 a new menu bar item can be registered but hidden. Open System Settings › Menu Bar and allow NetPulse. You can also make room to the right of the notch (quit or hide other menu bar items, or Command-drag NetPulse to the right), or double-click NetPulse in Applications to open its panel.

## Permissions

- **Location**: asked once, at first run. It is used only to read your Wi-Fi network's name (CoreWLAN returns no name without it), so usage can be tracked per network. Your location is never read, stored or sent. If you decline, networks are identified by a router fingerprint (the gateway's MAC address) and shown as "Wi-Fi network"; you can rename them in Settings.
- **Notifications**: asked only when you first enable a cap. Without them the caps still show in the popover (amber at 80%, red at 100%).
- **Launch at login**: the popover offers it once ("Turn on" / "Not now"), and it can be toggled in Settings › General. It uses the standard login item mechanism and shows up in System Settings › General › Login Items.

## How it measures

- **Interface totals** (live speed and network totals) come from the kernel's 64-bit interface counters (`sysctl` `NET_RT_IFLIST2`), sampled every second. Loopback and virtual interfaces (VPN tunnels, bridges, AWDL and similar) are not added on top of physical ones, so VPN traffic is counted once, on the interface it leaves through.
- **Per-app usage** comes from `/usr/bin/nettop`, run as one child process in delta mode, every 10 seconds in the app (live speed still updates every second), limited to Wi-Fi and wired interfaces (`-t wifi -t wired`) so a VPN's tunnel traffic is not counted a second time. Process IDs are mapped to their `.app` bundle, so helpers roll up to the parent app. Background services such as WebKit's networking process are assigned to the app that owns them using a private macOS lookup; if that fails they appear under "Apple WebKit".
- **Other / system** is the interface total minus everything attributed to apps, never below zero. It is always listed so the numbers visibly add up. It collects traffic nettop does not attribute to a process: ACK and header overhead, kernel and system traffic, and bytes from processes that started and exited between two samples. Outbound "Other" is large while you download, because acknowledgements and headers count on the interface but not in nettop's per-socket byte counts.
- **Device traffic, not ISP billing.** The numbers are what this Mac sent and received at the interface. Your provider may count differently (other devices, hotspot sharing, protocol overhead, their own measurement window), so do not treat a cap here as your provider's bill.
- **Storage**: usage is kept in 15-minute UTC buckets and aggregated in your current time zone, so local day, week and month boundaries are exact, including half-hour offsets. Writes are flushed every 30 seconds and on quit or sleep.
- **No data while NetPulse is not running.** It cannot count traffic when it is off or paused; those days are marked "Not monitored for part of this day". Sleep and nettop restarts are logged as gaps too but do not mark a day: no traffic flows while the Mac sleeps, and a nettop restart only interrupts the per-app split, not the totals.

### Measured accuracy and CPU

Measured on one Mac (macOS 26.6, Apple Silicon, Wi-Fi), with `netstat -ib -I en0` as the reference:

- Interface counters vs `netstat` over a 150 s download: ratio 0.9999 (down), 0.999 under upload load.
- Sum of attributed apps vs interface total: about 0.91 to 0.96 downloading, about 0.90 uploading. The rest is "Other / system".
- A curl download was attributed to curl within 0.24% of the payload size.
- CPU, NetPulse plus its nettop child together, shipping app (Release build, stacked menu bar label, popover closed, 600 s, cumulative `ps` CPU time): **0.97%** combined (NetPulse 0.59% + nettop 0.38%), just under the 1% budget. nettop's share varied from 0.38% to 0.73% across runs depending on network activity, so on a busy network expect the total to sit near or above 1%.

Details and raw numbers: [docs/superpowers/spikes/2026-10-28-findings.md](docs/superpowers/spikes/2026-10-28-findings.md).

## Privacy and your data

NetPulse makes no network calls and has no update checker. Everything is stored in one SQLite file:

```
~/Library/Application Support/NetPulse/usage.sqlite
```

To delete your history, quit NetPulse and remove that file (or the `NetPulse` folder). Settings live in the app's defaults; `defaults delete io.github.netpulse.NetPulse` resets them.

The full [privacy policy](https://venkataphanindravutla.github.io/NetPulse/privacy/) and [terms of use](https://venkataphanindravutla.github.io/NetPulse/terms/) are on the website.

## Known limits

- **Not on the Mac App Store and not sandboxed.** Per-app attribution needs `/usr/bin/nettop`, which the App Sandbox does not allow. The hardened runtime is on in every build, ad hoc included.
- **Short-lived processes** that start and exit between two 10 s samples may be missed and land in "Other / system".
- **WebKit attribution** relies on a private API; if it stops working, traffic goes to an "Apple WebKit" bucket rather than a guess.
- **Several active networks at once** (for example Wi-Fi plus Ethernet): the app switches to one nettop per interface type so per-network app sums stay honest. This mode has been tested logically but its CPU cost has not been measured.
- **Per-app numbers on a network are assigned to whichever network was primary** during each 10 s window.
- **Ethernet networks are identified by the Mac's Ethernet adapter**, so one dock or USB adapter used in two places counts as one network.
- **Caps cover network totals only**, not individual apps.
- Decimal units (1 GB = 1,000,000,000 bytes). Rates can be shown as MB/s or Mbps in Settings.

## Build from source

```sh
brew install xcodegen
git clone https://github.com/venkataPhanindraVutla/NetPulse.git && cd NetPulse
swift test                 # core logic, no app needed
xcodegen generate          # creates NetPulse.xcodeproj from project.yml
open NetPulse.xcodeproj    # run the NetPulse scheme
```

[CONTRIBUTING.md](CONTRIBUTING.md) is the full setup guide: requirements, signing, the debug harness, the website, and how releases are made. If you're working with an AI coding agent, point it at [AGENTS.md](AGENTS.md).

## Support

NetPulse is free and stays free. If it saved you from a surprise data bill, you can [buy me a coffee](https://buymeacoffee.com/venkat__). It helps pay for an Apple Developer account so future builds can be notarized. Stars, bug reports and pull requests help too.

## License

MIT. See [LICENSE](LICENSE).
