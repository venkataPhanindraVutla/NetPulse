#if DEBUG
import AppKit
import os

enum SystemEventsProbe {
    private static let log = Logger(subsystem: "NetPulse", category: "probe")

    @MainActor
    static func run(model: AppModel) async {
        let arguments = CommandLine.arguments
        if arguments.contains("--debug-pause") { await model.setPaused(true) }
        if arguments.contains("--debug-resume") { await model.setPaused(false) }
        guard arguments.contains("--simulate-sleep-wake") else { return }
        let center = NSWorkspace.shared.notificationCenter
        try? await Task.sleep(for: .seconds(8))
        log.info("posting willSleep")
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        try? await Task.sleep(for: .seconds(6))
        log.info("posting didWake")
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    }
}
#endif
