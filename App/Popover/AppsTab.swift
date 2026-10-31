import NetPulseCore
import SwiftUI

struct AppsTab: View {
    private static let visibleRows = 10
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let grand = model.apps.reduce(Totals(down: 0, up: 0)) { Totals(down: $0.down + $1.down, up: $0.up + $1.up) }
        let ranked = model.apps.filter { $0.id != "other" } + model.apps.filter { $0.id == "other" }
        let peak = max(ranked.map { $0.down + $0.up }.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 8) {
            Segmented(selection: $model.appsPeriod, options: [(.day, "Today"), (.week, "Week"), (.month, "Month")])
            HStack {
                Text("\(ByteFormatter.bytes(grand.total)) total")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 8)
                NetworkMenu(networks: model.networks, selection: $model.appsNetwork)
            }
            if model.snapshot?.appTrackingAvailable == false {
                Label("Per-app tracking paused — totals still accurate", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if ranked.isEmpty {
                Text("No traffic recorded yet")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                // The list scrolls inside a bounded height so the panel never grows past the screen.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(ranked) { app in
                            AppRow(app: app, peak: peak)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: AppRow.height * CGFloat(min(ranked.count, Self.visibleRows)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppRow: View {
    static let height: CGFloat = 34
    let app: AppUsage
    let peak: UInt64

    var body: some View {
        let total = app.down + app.up
        let isOther = app.id == "other"
        HStack(spacing: 8) {
            AppIconView(app: app)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName).lineLimit(1).foregroundStyle(isOther ? .secondary : .primary)
                GeometryReader { proxy in
                    let width = proxy.size.width * Double(total) / Double(peak)
                    let downShare = total > 0 ? Double(app.down) / Double(total) : 0
                    HStack(spacing: 0) {
                        Rectangle().fill(isOther ? Color.gray : Color.download).frame(width: width * downShare)
                        Rectangle().fill(isOther ? Color.gray.opacity(0.45) : Color.upload).frame(width: width * (1 - downShare))
                    }
                    .frame(width: max(width, total > 0 ? 2 : 0), alignment: .leading)
                    .clipShape(Capsule())
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            UsageText(totals: Totals(down: app.down, up: app.up))
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.displayName): downloaded \(Spoken.text(ByteFormatter.bytes(app.down))), uploaded \(Spoken.text(ByteFormatter.bytes(app.up)))")
    }
}
