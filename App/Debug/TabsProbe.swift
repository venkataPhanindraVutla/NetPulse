#if DEBUG
import AppKit
import os

/// `--probe-tabs <dir>`: opens the panel, switches through each tab, and saves a capture of the popover window after
/// each switch together with its frame, so tab-switch layout problems can be seen without clicking.
enum TabsProbe {
    static var directory: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--probe-tabs"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @MainActor
    static func run(model: AppModel, directory: String) async {
        let log = Logger(subsystem: "NetPulse", category: "probe")
        try? await Task.sleep(for: .seconds(3))
        StatusItemController.shared?.show()
        for (step, tab) in [PopoverTab.now, .apps, .history, .now, .history, .apps].enumerated() {
            model.tab = tab
            try? await Task.sleep(for: .seconds(2))
            let popover = NSApp.windows.first { $0.isVisible && $0.className.contains("Popover") }
            let content = popover?.contentViewController?.view
            log.info("tabs-probe: step=\(step) tab=\(String(describing: tab), privacy: .public) popover=\(popover.map { "\($0.frame)" } ?? "none", privacy: .public) content=\(content.map { "\($0.frame.size) fitting=\($0.fittingSize)" } ?? "none", privacy: .public) open=\(model.popoverOpen)")
            if let id = popover?.windowNumber {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l\(id)", "\(directory)/tab-\(step)-\(tab).png"]
                try? task.run()
                task.waitUntilExit()
            }
        }
        log.info("tabs-probe: done")
    }
}
#endif
