import AppKit
import NetPulseCore
import SwiftUI

struct PopoverFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.snapshot?.state ?? .monitoring
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(dotColor(state)).frame(width: 7, height: 7)
                Text(label(state))
            }
            .help(helpText(state))
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                let model = model
                Task { await model.setPaused(state != .paused) }
            } label: {
                Image(systemName: state == .paused ? "play.fill" : "pause.fill")
            }
            .help(state == .paused ? "Resume monitoring" : "Pause monitoring")
            .accessibilityLabel(state == .paused ? "Resume monitoring" : "Pause monitoring")
            SettingsOpener { Image(systemName: "gearshape.fill") }
                .help("Settings")
                .accessibilityLabel("Settings")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit NetPulse")
                .accessibilityLabel("Quit NetPulse")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.primary.opacity(0.045))
    }

    private func dotColor(_ state: MonitorState) -> Color {
        switch state {
        case .monitoring: .green
        case .paused: .gray
        case .degraded: .orange
        }
    }

    private func label(_ state: MonitorState) -> String {
        switch state {
        case .monitoring: "Monitoring"
        case .paused: "Paused"
        case .degraded: "Degraded"
        }
    }

    private func helpText(_ state: MonitorState) -> String {
        switch state {
        case .monitoring: "NetPulse is counting device traffic"
        case .paused: "Counting is paused"
        case .degraded(let reason): reason
        }
    }
}
