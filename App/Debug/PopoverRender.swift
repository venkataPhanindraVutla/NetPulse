#if DEBUG
import AppKit
import NetPulseCore
import SwiftUI

@MainActor
enum PopoverRender {
    static var directory: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-popover"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func makeModel() -> AppModel {
        let store = try! UsageStore(path: ":memory:")
        let model = AppModel(defaults: UserDefaults(suiteName: "netpulse.render")!, store: store, live: false)
        Task { await seed(store, model: model) }
        return model
    }

    private static func seed(_ store: UsageStore, model: AppModel) async {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let home = NetworkKey(fingerprint: "wifi:ssid:Home Wi-Fi", kind: .wifi, suggestedName: "Home Wi-Fi")
        let office = NetworkKey(fingerprint: "wifi:ssid:Office", kind: .wifi, suggestedName: "Office")
        func app(_ name: String, _ path: String?, group: AppGroup = .app) -> AppIdentity {
            AppIdentity(key: "app:\(name)", bundleID: nil, displayName: name, bundlePath: path, group: group)
        }
        let apps: [(AppIdentity, UInt64, UInt64)] = [
            (app("Safari", "/Applications/Safari.app"), 1_710_000_000, 130_000_000),
            (app("Mail", "/System/Applications/Mail.app"), 310_000_000, 310_000_000),
            (app("Software Update", nil, group: .system), 402_000_000, 0),
            (app("Notes", "/System/Applications/Notes.app"), 141_000_000, 9_000_000),
            (app("Some Tool", nil), 22_000_000, 88_000_000),
        ]
        var rows: [UsageRow] = []
        let todayBucket = PeriodBoundaries.bucketStart(today) + 900 * 20
        for (identity, down, up) in apps {
            rows.append(UsageRow(bucketStart: todayBucket, network: home, app: identity, down: down, up: up))
        }
        rows.append(UsageRow(bucketStart: todayBucket, network: home, app: nil, down: 3_210_000_000, up: 412_000_000))
        let month = calendar.dateInterval(of: .month, for: now)!
        var day = month.start
        var n = 0
        while day < today {
            let bucket = PeriodBoundaries.bucketStart(day) + 900 * 40
            let factor = UInt64(20 + (n * 37) % 70)
            let down = factor * 37_000_000, up = factor * 4_000_000
            rows.append(UsageRow(bucketStart: bucket, network: home, app: nil, down: down, up: up))
            rows.append(UsageRow(bucketStart: bucket, network: home, app: apps[0].0, down: down / 2, up: up / 2))
            n += 1
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let lastMonthDay = calendar.date(byAdding: .month, value: -1, to: today)!
        rows.append(UsageRow(bucketStart: PeriodBoundaries.bucketStart(lastMonthDay), network: home, app: nil, down: 71_000_000_000, up: 8_300_000_000))
        rows.append(UsageRow(bucketStart: todayBucket, network: office, app: nil, down: 200_000_000, up: 20_000_000))
        try? await store.write(rows)
        let gapDay = calendar.date(byAdding: .day, value: -6, to: today)!
        try? await store.recordGap(start: gapDay.addingTimeInterval(3600), end: gapDay.addingTimeInterval(7200), reason: "not running")
        let networks = (try? await store.networks()) ?? []
        if let id = networks.first(where: { $0.displayName == "Home Wi-Fi" })?.id {
            try? await store.saveCap(Cap(networkID: id, period: .monthly, limitBytes: 100_000_000_000, enabled: true))
            model.historyNetwork = id
        }
        model.snapshot = EngineSnapshot(
            speed: Speed(down: 8_400_000, up: 1_200_000),
            primaryNetwork: networks.first(where: { $0.displayName == "Home Wi-Fi" }),
            state: .monitoring, appTrackingAvailable: true)
    }

    static func checkSpoken() {
        let cases: [(String, String)] = [
            (ByteFormatter.rate(8_400_000, unit: .bytesPerSecond), "8.4 megabytes per second"),
            (ByteFormatter.bytes(3_210_000_000), "3.21 gigabytes"),
            (ByteFormatter.bytes(950), "950 bytes"),
            (ByteFormatter.rate(1_200_000, unit: .bitsPerSecond), "9.6 megabits per second"),
        ]
        for (input, expected) in cases {
            let actual = Spoken.text(input)
            assert(actual == expected, "Spoken.text(\(input)) = \(actual), expected \(expected)")
            print("SPOKEN \(actual == expected ? "ok" : "FAIL"): \(input) -> \(actual)")
        }
    }

    static func run(model: AppModel, directory: String) async {
        checkSpoken()
        try? await Task.sleep(for: .seconds(1))
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        await model.refreshUsage()
        for tab in PopoverTab.allCases {
            model.tab = tab
            model.appsPeriod = .day
            await model.refreshUsage()
            await dumpAccessibility(model: model, name: tab.title)
        }
        let cases: [(String, PopoverTab, Bool)] = [
            ("now", .now, false), ("apps", .apps, false), ("history", .history, false),
        ]
        for dark in [false, true] {
            for (name, tab, _) in cases {
                model.tab = tab
                await save(model: model, dark: dark, path: "\(directory)/\(name)-\(dark ? "dark" : "light").png")
            }
        }
        if let cap = model.currentCap?.cap, let store = Optional(model.store) {
            var warn = cap
            warn.limitBytes = 70_000_000_000
            try? await store.saveCap(warn)
            await model.refreshUsage()
            model.tab = .now
            await save(model: model, dark: false, path: "\(directory)/now-warning-light.png")
            warn.limitBytes = 50_000_000_000
            try? await store.saveCap(warn)
            await model.refreshUsage()
            await save(model: model, dark: true, path: "\(directory)/now-exceeded-dark.png")
            try? await store.saveCap(Cap(networkID: cap.networkID, period: .monthly, limitBytes: 0, enabled: false))
            await model.refreshUsage()
            await save(model: model, dark: false, path: "\(directory)/now-nocap-light.png")
            try? await store.saveCap(Cap(networkID: cap.networkID, period: .monthly, limitBytes: 100_000_000_000, enabled: true))
            try? await store.saveCap(Cap(networkID: cap.networkID, period: .daily, limitBytes: 5_000_000_000, enabled: true))
            await model.refreshUsage()
            await save(model: model, dark: false, path: "\(directory)/now-daily-light.png")
        }
        model.snapshot = EngineSnapshot(speed: .zero, primaryNetwork: model.snapshot?.primaryNetwork, state: .paused, appTrackingAvailable: false)
        model.tab = .apps
        model.appsPeriod = .week
        try? await Task.sleep(for: .milliseconds(600))
        await save(model: model, dark: false, path: "\(directory)/apps-paused-notice-light.png")
        print("render done")
        exit(0)
    }

    static func probe(model: AppModel) async {
        try? await Task.sleep(for: .seconds(4))
        await model.refreshUsage()
        print("probe: networks=\(model.networks.map(\.displayName)) today=\(model.today) topApps=\(model.topApps.map(\.displayName)) apps=\(model.apps.count) days=\(model.days.count) cap=\(String(describing: model.currentCap)) periodTotals=\(model.periodTotals.map { "\($0.label)=\($0.totals.total)" })")
        exit(0)
    }

    private static func dumpAccessibility(model: AppModel, name: String) async {
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            _ = NSApp.perform(setter, with: true as NSNumber, with: attribute)
        }
        let hosting = NSHostingView(rootView: PopoverView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1200))
        print("A11Y \(name)")
        func read(_ object: NSObject, _ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        func walk(_ element: Any, depth: Int) {
            guard let object = element as? NSObject, depth < 8 else { return }
            let label = read(object, "accessibilityLabel") as? String ?? ""
            let value = read(object, "accessibilityValue").map { "\($0)" } ?? ""
            let role = read(object, "accessibilityRole").map { "\($0)" } ?? "?"
            if !label.isEmpty || !value.isEmpty {
                print("A11Y \(String(repeating: " ", count: depth))[\(role)] \(label)\(value.isEmpty ? "" : " = \(value)")")
            }
            for child in (read(object, "accessibilityChildren") as? [Any] ?? []) { walk(child, depth: depth + 1) }
        }
        walk(hosting, depth: 0)
        window.orderOut(nil)
    }

    private static func save(model: AppModel, dark: Bool, path: String) async {
        let hosting = NSHostingView(rootView: PopoverView().background(Color(nsColor: .windowBackgroundColor)).environment(model))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        let size = hosting.fittingSize
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.lockFocus()
        window.appearance?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let final = NSBitmapImageRep(data: tiff) else { return }
        try? final.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
#endif
