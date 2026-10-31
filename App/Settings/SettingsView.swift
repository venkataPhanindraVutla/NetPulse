import NetPulseCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            NetworksSettings()
                .tabItem { Label("Networks", systemImage: "wifi") }
                .tag(SettingsTab.networks)
        }
        .frame(width: 460, height: 440)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItemService.isEnabled
    @State private var needsApproval = LoginItemService.requiresApproval
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Menu bar label", selection: $model.labelStyle) {
                ForEach(LabelStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Speed units", selection: $model.rateUnit) {
                Text("MB/s").tag(RateUnit.bytesPerSecond)
                Text("Mbps").tag(RateUnit.bitsPerSecond)
            }
            .pickerStyle(.segmented)

            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if needsApproval {
                    note("Requires approval in System Settings › Login Items")
                }
                if let loginError { note(loginError) }
            }

            Section {
                LabeledContent("Notifications") { Text(notificationValue) }
                if let detail = notificationDetail { note(detail) }
            }

            Section {
                Text("NetPulse measures device traffic on this Mac. Totals can be incomplete while the app isn't running, while the Mac sleeps, or when a network can't be identified, and some system traffic shows up as Other / system.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("About the numbers")
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshNotificationStatus() }
        .onAppear(perform: syncLogin)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private var notificationValue: String {
        switch model.notificationStatus {
        case .authorized: "On"
        case .denied: "Off"
        case .notDetermined, .unknown: "Not requested yet"
        }
    }

    private var notificationDetail: String? {
        switch model.notificationStatus {
        case .authorized: nil
        case .denied: "Notifications are off — caps will still show in the popover."
        case .notDetermined, .unknown: "NetPulse asks when you turn on your first cap."
        }
    }

    private func syncLogin() {
        launchAtLogin = LoginItemService.isEnabled
        needsApproval = LoginItemService.requiresApproval
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            try LoginItemService.set(on)
        } catch {
            loginError = "Couldn't change launch at login: \(error.localizedDescription)"
        }
        syncLogin()
    }
}

extension LabelStyle {
    var title: String {
        switch self {
        case .stacked: "Stacked up / down"
        case .singleLine: "Single line"
        case .downloadOnly: "Download only"
        case .iconOnly: "Icon only"
        }
    }
}
