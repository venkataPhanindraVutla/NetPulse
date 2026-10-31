#if DEBUG
import AppKit
import NetPulseCore
import os
import SwiftUI

@MainActor
enum SettingsProbe {
    static var requestedTab: SettingsTab? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--open-settings") }) else { return nil }
        return arg.hasSuffix("=networks") ? .networks : .general
    }

    static var window: NSWindow?

    static func open(model: AppModel) async {
        try? await Task.sleep(for: .seconds(1.5))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let sent = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        Logger(subsystem: "NetPulse", category: "probe").info("showSettingsWindow sent=\(sent)")
        try? await Task.sleep(for: .seconds(1))
        if NSApp.windows.contains(where: { $0.isVisible && $0.title.contains("Settings") || $0.title == "General" || $0.title == "Networks" }) { return }
        let host = NSHostingController(rootView: SettingsView().environment(model))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings (debug host)"
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.window = window
    }
}

/// Opens the popover, presses its Settings button through accessibility, and logs what happened.
@MainActor
enum StatusItemProbe {
    static func run(model: AppModel) async {
        let log = Logger(subsystem: "NetPulse", category: "probe")
        try? await Task.sleep(for: .seconds(2))
        guard let controller = StatusItemController.shared else { return log.error("status-item: no controller") }
        controller.show()
        try? await Task.sleep(for: .seconds(1.5))
        let popover = NSApp.windows.first { $0.isVisible && $0.className.contains("Popover") }
        log.info("status-item: shown popoverOpen=\(model.popoverOpen) window=\(popover.map { "\($0.frame)" } ?? "none", privacy: .public)")
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        _ = NSApp.perform(setter, with: true as NSNumber, with: "AXEnhancedUserInterface")
        try? await Task.sleep(for: .seconds(0.5))
        func find(_ element: Any, depth: Int) -> NSObject? {
            guard let object = element as? NSObject, depth < 12 else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityLabel")), object.value(forKey: "accessibilityLabel") as? String == "Settings" { return object }
            let children = object.responds(to: NSSelectorFromString("accessibilityChildren")) ? object.value(forKey: "accessibilityChildren") as? [Any] ?? [] : []
            return children.lazy.compactMap { find($0, depth: depth + 1) }.first
        }
        guard let view = popover?.contentView, let gear = find(view, depth: 0) else { return log.error("status-item: no Settings button") }
        gear.perform(NSSelectorFromString("accessibilityPerformPress"))
        try? await Task.sleep(for: .seconds(1.5))
        let settings = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
        log.info("status-item: after Settings press popoverOpen=\(model.popoverOpen) settingsWindow=\(settings?.title ?? "none", privacy: .public) key=\(settings?.isKeyWindow ?? false)")
        settings?.close()
    }
}

@MainActor
enum CapAlertProbe {
    static func run(model: AppModel) async {
        let log = Logger(subsystem: "NetPulse", category: "probe")
        let status = await model.notifications.status()
        log.info("test-cap-alert: notification status=\(String(describing: status), privacy: .public)")
        let boundaries = PeriodBoundaries(calendar: Calendar.current)
        let now = Date()
        let cap = Cap(networkID: 1, period: .monthly, limitBytes: 80_000_000_000, enabled: true)
        let interval = CapEvaluator.periodInterval(cap, billingDay: 15, now: now, boundaries: boundaries)
        let first = CapEvaluator.evaluate(cap, used: 64_200_000_000, periodStart: interval.start)
        let second = CapEvaluator.evaluate(first.updated, used: 64_300_000_000, periodStart: interval.start)
        log.info("test-cap-alert: first=\(first.alert?.threshold ?? -1) second=\(second.alert?.threshold ?? -1)")
        if let alert = first.alert {
            _ = await model.notifications.post(alert, networkName: "Test Network", resets: interval.end)
            log.info("test-cap-alert: posted 80% for 'Test Network' resets \(interval.end, privacy: .public)")
        }
    }
}
#endif
