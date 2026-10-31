import AppKit
import NetPulseCore
import SwiftUI

extension Color {
    static let download = Color.blue
    static let upload = Color.green
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.3)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}

struct Pill: View {
    let text: String
    var menu = false

    var body: some View {
        HStack(spacing: 3) {
            Text(text).lineLimit(1)
            if menu {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary.opacity(0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .textCase(nil)
        .tracking(0)
    }
}

struct NetworkMenu: View {
    let networks: [StoredNetwork]
    @Binding var selection: Int64?

    var body: some View {
        let name = networks.first { $0.id == selection }?.displayName ?? "All networks"
        Menu {
            Picker("Network", selection: $selection) {
                Text("All networks").tag(Int64?.none)
                ForEach(networks) { network in
                    Text(network.displayName).tag(Int64?.some(network.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Pill(text: name, menu: true)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Network")
        .accessibilityValue(name)
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundlePath path: String) -> NSImage? {
        if let hit = cache[path] { return hit }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

struct AppIconView: View {
    let app: AppUsage

    var body: some View {
        Group {
            if let path = app.bundlePath, let image = IconCache.icon(forBundlePath: path) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if app.id == "other" || app.group == .system {
                Image(systemName: "gearshape").resizable().scaledToFit().padding(2).foregroundStyle(.secondary)
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().padding(1).foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

struct UsageText: View {
    let totals: Totals

    var body: some View {
        Text("↓\(ByteFormatter.bytes(totals.down)) ↑\(ByteFormatter.bytes(totals.up))")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.8))
            .lineLimit(1)
            .fixedSize()
    }
}

struct SettingsOpener<Label: View>: View {
    var tab: SettingsTab?
    @ViewBuilder var label: Label
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            if let tab { model.settingsTab = tab }
            SettingsWindow.open(openSettings)
        } label: { label }
            .buttonStyle(.plain)
    }
}

@MainActor
enum SettingsWindow {
    static func open(_ openSettings: OpenSettingsAction) {
        StatusItemController.shared?.close()
        NSApp.activate()
        openSettings()
        DispatchQueue.main.async {
            NSApp.windows.first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }?.makeKeyAndOrderFront(nil)
        }
    }
}

enum Spoken {
    private static let units: [(String, String)] = [
        ("TB/s", "terabytes per second"), ("GB/s", "gigabytes per second"), ("MB/s", "megabytes per second"),
        ("KB/s", "kilobytes per second"), ("B/s", "bytes per second"),
        ("Tbps", "terabits per second"), ("Gbps", "gigabits per second"), ("Mbps", "megabits per second"),
        ("Kbps", "kilobits per second"), ("bps", "bits per second"),
        ("TB", "terabytes"), ("GB", "gigabytes"), ("MB", "megabytes"), ("KB", "kilobytes"), ("B", "bytes"),
    ]

    static func text(_ formatted: String) -> String {
        for (suffix, word) in units where formatted.hasSuffix(" " + suffix) {
            return formatted.dropLast(suffix.count) + word
        }
        return formatted
    }
}

enum DateText {
    private static let month = make("MMMM")
    private static let monthYear = make("MMMM yyyy")
    private static let monthDay = make("MMMd")

    private static func make(_ template: String) -> DateFormatter {
        let format = DateFormatter()
        format.locale = .autoupdatingCurrent
        format.timeZone = .autoupdatingCurrent
        format.calendar = .autoupdatingCurrent
        format.setLocalizedDateFormatFromTemplate(template)
        return format
    }

    @MainActor static func month(_ date: Date) -> String { month.string(from: date) }
    @MainActor static func monthYear(_ date: Date) -> String { monthYear.string(from: date) }
    @MainActor static func monthDay(_ date: Date) -> String { monthDay.string(from: date) }
}
