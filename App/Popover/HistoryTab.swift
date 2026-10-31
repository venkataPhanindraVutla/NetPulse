import Charts
import NetPulseCore
import SwiftUI

struct HistoryTab: View {
    @Environment(AppModel.self) private var model

    private var calendar: Calendar { .current }
    private var monthTitle: String {
        DateText.monthYear(model.historyMonthStart)
    }
    private var isCurrentMonth: Bool {
        model.historyMonth == AppModel.month(of: Date())
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    monthNavigation
                    Spacer(minLength: 8)
                    NetworkMenu(networks: model.networks, selection: $model.historyNetwork)
                }
                DailyChart()
                    .frame(height: 96)
                HStack {
                    Text(firstDayLabel)
                    Spacer()
                    Text(isCurrentMonth ? "today" : lastDayLabel)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.days.contains(where: \.hasGap) {
                    Label("Not monitored for part of this day (NetPulse wasn't running or was paused)", systemImage: "circle.dotted")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().opacity(0.6)
            VStack(spacing: 6) {
                ForEach(Array(model.periodTotals.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.label)
                        Spacer(minLength: 8)
                        Text("↓ \(ByteFormatter.bytes(row.totals.down)) · ↑ \(ByteFormatter.bytes(row.totals.up))")
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                }
            }
            .font(.system(size: 12)).monospacedDigit()
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var monthNavigation: some View {
        HStack(spacing: 6) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month")
            Text(monthTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 96)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(isCurrentMonth)
                .accessibilityLabel("Next month")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .semibold))
    }

    private func shift(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: model.historyMonthStart) else { return }
        model.historyMonth = AppModel.month(of: next)
    }

    private var firstDayLabel: String { dayLabel(model.days.first?.id) }
    private var lastDayLabel: String { dayLabel(model.days.last?.id) }

    private func dayLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return DateText.monthDay(date)
    }
}

private struct DailyChart: View {
    @Environment(AppModel.self) private var model

    private var summary: String {
        let total = model.days.reduce(UInt64(0)) { $0 + $1.totals.total }
        guard let peak = model.days.max(by: { $0.totals.total < $1.totals.total }), peak.totals.total > 0 else { return "No traffic recorded" }
        let gaps = model.days.filter(\.hasGap).map { DateText.monthDay($0.id) }
        let gapNote = gaps.isEmpty ? "" : ". Not monitored for part of \(gaps.joined(separator: ", "))"
        return "Month total \(Spoken.text(ByteFormatter.bytes(total))). Peak day \(DateText.monthDay(peak.id)), \(Spoken.text(ByteFormatter.bytes(peak.totals.total)))\(gapNote)"
    }

    var body: some View {
        let calendar = Calendar.current
        let peak = Double(model.days.map { $0.totals.total }.max() ?? 0)
        let ceiling = max(peak, model.dailyPace ?? 0, 1) * 1.15
        let start = model.days.first?.id ?? Date()
        let end = calendar.date(byAdding: .day, value: 1, to: model.days.last?.id ?? start) ?? start
        Chart {
            ForEach(model.days) { day in
                if day.hasGap {
                    RuleMark(x: .value("Day", day.id, unit: .day), yStart: .value("Bytes", 0), yEnd: .value("Bytes", ceiling))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [1.5, 2.5]))
                        .foregroundStyle(Color.orange.opacity(0.7))
                }
                BarMark(x: .value("Day", day.id, unit: .day), y: .value("Bytes", Double(day.totals.total)))
                    .foregroundStyle(Color.download.opacity(calendar.isDateInToday(day.id) ? 1 : 0.35))
                    .cornerRadius(2)
            }
            if let pace = model.dailyPace {
                RuleMark(y: .value("Daily pace", pace))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .annotation(position: .top, alignment: .trailing, spacing: 1) {
                        Text("daily pace for cap").font(.system(size: 9)).foregroundStyle(.red)
                            .padding(.horizontal, 2)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                    }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) { Divider() }
        }
        .overlay {
            if peak == 0 {
                Text("No traffic recorded").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily usage chart")
        .accessibilityValue(summary)
    }
}
