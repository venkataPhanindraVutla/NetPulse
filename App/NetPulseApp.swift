import AppKit
import NetPulseCore
import SwiftUI

@main
struct NetPulseApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if let directory = PopoverRender.directory {
            let preview = PopoverRender.makeModel()
            _model = State(initialValue: preview)
            Task { @MainActor in await PopoverRender.run(model: preview, directory: directory) }
            return
        }
        #endif
        let live = AppModel()
        Task { @MainActor in
            StatusItemController.shared = StatusItemController(model: live)
            LocationPermission.start(
                onAuthorized: { Task { await live.engine.refreshNetworkIdentity() } },
                onDetermined: { Task { await live.engine.setIdentityPending(false) } })
        }
        #if DEBUG
        if let tab = SettingsProbe.requestedTab {
            live.settingsTab = tab
            Task { @MainActor in await SettingsProbe.open(model: live) }
        }
        if CommandLine.arguments.contains("--probe-status-item") {
            Task { @MainActor in await StatusItemProbe.run(model: live) }
        }
        if CommandLine.arguments.contains("--test-cap-alert") {
            Task { @MainActor in await CapAlertProbe.run(model: live) }
        }
        #endif
        #if DEBUG
        Task { @MainActor in await SystemEventsProbe.run(model: live) }
        if CommandLine.arguments.contains("--probe-refresh") {
            Task { @MainActor in await PopoverRender.probe(model: live) }
        }
        #endif
        _model = State(initialValue: live)
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
