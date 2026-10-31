import Foundation

public enum Period: String, Codable, Sendable {
    case day
    case week
    case month
}

public struct PeriodBoundaries: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public func interval(_ p: Period, containing date: Date) -> DateInterval {
        let component: Calendar.Component
        switch p {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        return calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: date, duration: 0)
    }

    public func billingMonth(containing date: Date, billingDay: Int) -> DateInterval {
        let day = min(max(billingDay, 1), 28)
        let parts = calendar.dateComponents([.year, .month], from: date)
        let thisMonth = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: day))!
        let start = date >= thisMonth ? thisMonth : calendar.date(byAdding: .month, value: -1, to: thisMonth)!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    public static func bucketStart(_ d: Date) -> Int64 {
        Int64((d.timeIntervalSince1970 / 900).rounded(.down)) * 900
    }
}
