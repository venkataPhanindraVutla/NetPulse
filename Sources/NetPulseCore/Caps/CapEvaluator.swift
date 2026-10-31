import Foundation

public enum CapPeriod: String, Codable, Sendable {
    case daily
    case monthly
}

public struct Cap: Sendable, Equatable {
    public let networkID: Int64
    public let period: CapPeriod
    public var limitBytes: UInt64
    public var enabled: Bool
    public var lastAlertPeriodStart: Date?
    public var lastAlertThreshold: Int?

    public init(
        networkID: Int64, period: CapPeriod, limitBytes: UInt64, enabled: Bool,
        lastAlertPeriodStart: Date? = nil, lastAlertThreshold: Int? = nil
    ) {
        self.networkID = networkID
        self.period = period
        self.limitBytes = limitBytes
        self.enabled = enabled
        self.lastAlertPeriodStart = lastAlertPeriodStart
        self.lastAlertThreshold = lastAlertThreshold
    }
}

public struct CapAlert: Sendable, Equatable {
    public let networkID: Int64
    public let period: CapPeriod
    public let threshold: Int
    public let used: UInt64
    public let limit: UInt64
}

public enum CapLevel: Sendable {
    case normal, warning, exceeded
}

public enum CapEvaluator {
    public static let thresholds = [80, 100]

    public static func periodInterval(_ c: Cap, billingDay: Int, now: Date, boundaries: PeriodBoundaries) -> DateInterval {
        switch c.period {
        case .daily: boundaries.interval(.day, containing: now)
        case .monthly: boundaries.billingMonth(containing: now, billingDay: billingDay)
        }
    }

    public static func evaluate(_ c: Cap, used: UInt64, periodStart: Date) -> (alert: CapAlert?, updated: Cap) {
        guard c.enabled, c.limitBytes > 0 else { return (nil, c) }
        let last = c.lastAlertPeriodStart == periodStart ? c.lastAlertThreshold : nil
        guard let threshold = thresholds.last(where: { reached($0, used: used, limit: c.limitBytes) }),
              threshold > (last ?? 0) else { return (nil, c) }
        var updated = c
        updated.lastAlertPeriodStart = periodStart
        updated.lastAlertThreshold = threshold
        let alert = CapAlert(networkID: c.networkID, period: c.period, threshold: threshold, used: used, limit: c.limitBytes)
        return (alert, updated)
    }

    public static func level(used: UInt64, limit: UInt64) -> CapLevel {
        guard limit > 0 else { return .normal }
        if reached(100, used: used, limit: limit) { return .exceeded }
        if reached(80, used: used, limit: limit) { return .warning }
        return .normal
    }

    private static func reached(_ percent: Int, used: UInt64, limit: UInt64) -> Bool {
        let lhs = used.multipliedFullWidth(by: 100)
        let rhs = limit.multipliedFullWidth(by: UInt64(percent))
        return (lhs.high, lhs.low) >= (rhs.high, rhs.low)
    }
}
