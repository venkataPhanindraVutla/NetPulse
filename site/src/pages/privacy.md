---
layout: ../layouts/Legal.astro
title: Privacy Policy
description: NetPulse collects nothing. This page explains what the app keeps on your Mac, what this website does, and how to delete everything.
path: privacy/
updated: October 31, 2026
---

## The short version

- The NetPulse app has **no account, no analytics, no telemetry, no crash reporting and no update checker**. It never opens a network connection of its own.
- Everything it records stays in one file on your Mac, and you can delete it at any time.
- This website sets **no cookies** and runs **no analytics or trackers**. Its fonts and images are served from the site itself.

## What the app stores on your Mac

NetPulse keeps its history in a single SQLite database:

`~/Library/Application Support/NetPulse/usage.sqlite`

It contains:

- **Traffic totals**: bytes downloaded and uploaded, in 15-minute buckets, per network and per app.
- **App names**: the name, bundle identifier and location of each app that used the network, so helpers can be grouped under their app.
- **Networks**: a name for each network and an identifier used to recognise it again. For Wi-Fi this is the network name (SSID), or the router's hardware (MAC) address when the name can't be read. For Ethernet it is the hardware address of your Mac's Ethernet adapter. You can rename networks in Settings.
- **Caps and alerts**: any data caps you set, and which alerts have already been shown.
- **Gaps**: times when NetPulse wasn't running, so those days can be marked instead of guessed.

Your settings (menu bar style, units and similar) are kept in the app's standard macOS preferences.

None of this leaves your Mac. NetPulse does not send it to the developer or to anyone else. If you back up your Mac (for example with Time Machine or iCloud), the file is included in that backup like any other file.

## Permissions the app asks for

- **Location**: used only to read the name of the Wi-Fi network you're on, because macOS doesn't reveal network names without it. NetPulse never reads, stores or sends your location. It's optional; if you decline, Wi-Fi networks are recognised by the router's hardware address instead.
- **Notifications**: requested only when you turn on a data cap, and used only for the 80% and 100% alerts.
- **Launch at login**: optional, using the standard macOS login item. You can turn it off in Settings or in System Settings › General › Login Items.

To measure per-app traffic, NetPulse runs macOS's built-in `nettop` tool. Its output is read in memory and turned into the totals above. NetPulse never inspects the contents of your traffic.

## Deleting your data

1. Quit NetPulse.
2. Delete the folder `~/Library/Application Support/NetPulse`.
3. Optionally, reset its settings by running `defaults delete io.github.netpulse.NetPulse` in Terminal.

Deleting the app from Applications and doing the steps above removes everything NetPulse created.

## This website

This site is a static page hosted on **GitHub Pages**. When you visit, GitHub receives your IP address and standard request details, as every web host does, and handles them under the [GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement). The developer has no access to those logs and runs no analytics of their own.

The site sets no cookies. Fonts and images are self-hosted, so loading the page doesn't contact Google Fonts or any other third party.

## Links to other services

The site and the app link to services that have their own privacy policies:

- **GitHub**, for the source code, downloads and bug reports.
- **Buy Me a Coffee**, if you choose to support the project. Payments and any name or message you leave are handled by Buy Me a Coffee under [its privacy policy](https://www.buymeacoffee.com/privacy-policy). The developer sees what Buy Me a Coffee shows a creator, such as your name and message if you add them. NetPulse never receives payment details.
- **Unsplash**, credited for the hero photo.

## Children

NetPulse doesn't collect personal information from anyone, including children.

## Changes

If this policy changes, the new version will be posted on this page with a new date, and the change will be visible in the project's public history on GitHub.

## Contact

Questions about privacy? Open an issue on [GitHub](https://github.com/venkataPhanindraVutla/NetPulse/issues).
