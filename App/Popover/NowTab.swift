import NetPulseCore
import os
import SwiftUI

struct NowTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let speed = model.snapshot?.speed ?? .zero
        VStack(spacing: 0) {
            FirstRunRows()
            section {
                SectionHeader(title: "Live") {
                    Pill(text: model.snapshot?.primaryNetwork?.displayName ?? "No network")
                }
                .padding(.bottom, 8)
                HStack(alignment: .top, spacing: 18) {
                    figure(ByteFormatter.rate(speed.down, unit: model.rateUnit), prefix: "↓", color: .download, caption: "download",
                           spoken: "Download speed \(Spoken.text(ByteFormatter.rate(speed.down, unit: model.rateUnit)))")
                    figure(ByteFormatter.rate(speed.up, unit: model.rateUnit), prefix: "↑", color: .upload, caption: "upload",
                           spoken: "Upload speed \(Spoken.text(ByteFormatter.rate(speed.up, unit: model.rateUnit)))")
                }
            }
            divider
            section {
                SectionHeader("Today").padding(.bottom, 8)
                HStack(alignment: .top, spacing: 18) {
                    figure(ByteFormatter.bytes(model.today.down), prefix: nil, color: .primary, caption: "↓ downloaded",
                           spoken: "Downloaded today \(ByteFormatter.bytes(model.today.down))")
                    figure(ByteFormatter.bytes(model.today.up), prefix: nil, color: .primary, caption: "↑ uploaded",
                           spoken: "Uploaded today \(ByteFormatter.bytes(model.today.up))")
                }
            }
            divider
            if model.snapshot?.primaryNetwork != nil {
                section { CapSection() }
                divider
            }
            section {
                SectionHeader(title: "Top apps today") {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { model.tab = .apps }
                    } label: {
                        Text("All apps ›").font(.system(size: 11)).textCase(nil).tracking(0).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 4)
                if model.topApps.isEmpty {
                    Text("No app traffic yet today")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 4)
                }
                ForEach(model.topApps) { app in
                    HStack(spacing: 8) {
                        AppIconView(app: app)
                        Text(app.displayName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(ByteFormatter.bytes(app.down + app.up))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.primary.opacity(0.8))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func figure(_ value: String, prefix: String?, color: Color, caption: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(prefix.map { "\($0) \(value)" } ?? value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View { Divider().opacity(0.6) }
}

private struct CapSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let current = model.currentCap, let interval = model.capInterval {
            let limit = current.cap.limitBytes, used = current.used
            let level = CapEvaluator.level(used: used, limit: limit)
            let color: Color = switch level {
            case .normal: .blue
            case .warning: .orange
            case .exceeded: .red
            }
            let name = model.snapshot?.primaryNetwork?.displayName ?? ""
            let daily = current.cap.period == .daily
            let left = daysLeft(in: interval)
            let period = daily ? "Today" : periodName(interval)
            let remaining = Spoken.text(ByteFormatter.bytes(limit > used ? limit - used : 0))
            let spoken = level == .exceeded
                ? "\(name), \(period): cap reached, \(Spoken.text(ByteFormatter.bytes(used))) of \(Spoken.text(ByteFormatter.bytes(limit))) used, \(Spoken.text(ByteFormatter.bytes(used - limit))) over"
                : daily
                ? "\(name), \(period): \(Spoken.text(ByteFormatter.bytes(used))) of \(Spoken.text(ByteFormatter.bytes(limit))) used, \(remaining) left today"
                : "\(name), \(period): \(Spoken.text(ByteFormatter.bytes(used))) of \(Spoken.text(ByteFormatter.bytes(limit))) used, \(left) \(left == 1 ? "day" : "days") left, about \(Spoken.text(ByteFormatter.bytes((limit - used) / UInt64(left)))) per day"
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "\(name) · \(period)") {
                    Text("\(ByteFormatter.bytes(used)) / \(ByteFormatter.bytes(limit))")
                        .font(.system(size: 11)).textCase(nil).tracking(0).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(color)
                            .frame(width: max(proxy.size.width * min(Double(used) / Double(limit), 1), used > 0 ? 6 : 0))
                    }
                }
                .frame(height: 6)
                .padding(.vertical, 6)
                .animation(.easeOut(duration: 0.3), value: used)
                HStack {
                    if level == .exceeded {
                        Text("Cap reached")
                    } else if daily {
                        Text("Resets at midnight")
                    } else {
                        Text("\(left) \(left == 1 ? "day" : "days") left")
                    }
                    Spacer()
                    if level == .exceeded {
                        Text("\(ByteFormatter.bytes(used - limit)) over")
                    } else if daily {
                        Text("\(ByteFormatter.bytes(limit - used)) left")
                    } else {
                        Text("~\(ByteFormatter.bytes((limit - used) / UInt64(left)))/day")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(level == .normal ? Color.secondary : color).monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
        } else {
            SectionHeader("Data cap").padding(.bottom, 6)
            SettingsOpener(tab: .networks) {
                Text("Set a cap…").font(.system(size: 12)).foregroundStyle(Color.accentColor)
            }
        }
    }

    private func daysLeft(in interval: DateInterval) -> Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: interval.end).day ?? 1
        return max(days, 1)
    }

    private func periodName(_ interval: DateInterval) -> String {
        let calendar = Calendar.current
        if calendar.component(.day, from: interval.start) == 1 {
            return DateText.month(interval.start)
        }
        return "\(DateText.monthDay(interval.start)) – \(DateText.monthDay(interval.end.addingTimeInterval(-1)))"
    }
}

private struct FirstRunRows: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    private let log = Logger(subsystem: "NetPulse", category: "login")

    var body: some View {
        let unnamed = model.snapshot?.primaryNetwork.flatMap { Self.needsName($0) && !model.handledNameNetworks.contains($0.id) ? $0 : nil }
        let offerLogin = !model.loginOffered && !LoginItemService.isEnabled
        if unnamed != nil || offerLogin {
            VStack(spacing: 0) {
                if let unnamed {
                    row {
                        Text("New network detected").foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        SettingsOpener(tab: .networks) {
                            Text("Name it").foregroundStyle(Color.accentColor)
                        }
                        Button { model.markNameHandled(unnamed.id) } label: { Image(systemName: "xmark") }
                            .foregroundStyle(.secondary)
                            .help("Dismiss")
                            .accessibilityLabel("Dismiss")
                    }
                    .buttonStyle(.plain)
                }
                if offerLogin {
                    row {
                        Text("Start NetPulse at login?").foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Button("Turn on", action: turnOn)
                            .foregroundStyle(Color.accentColor)
                        Button("Not now") { model.markLoginOffered() }
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Divider().opacity(0.6)
            }
        }
    }

    private func turnOn() {
        do {
            try LoginItemService.set(true)
        } catch {
            log.error("login item registration failed: \(String(describing: error), privacy: .public)")
            model.settingsTab = .general
            SettingsWindow.open(openSettings)
            model.markLoginOffered()
            return
        }
        if LoginItemService.requiresApproval {
            model.settingsTab = .general
            SettingsWindow.open(openSettings)
        }
        model.markLoginOffered()
    }

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10, content: content)
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
    }

    static func needsName(_ network: StoredNetwork) -> Bool {
        network.key.fingerprint.hasPrefix("wifi:gw:") || network.key.fingerprint.hasPrefix("eth:")
    }
}
