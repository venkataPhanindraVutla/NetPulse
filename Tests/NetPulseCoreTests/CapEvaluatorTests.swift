import Foundation
import Testing
@testable import NetPulseCore

private func iso(_ s: String) -> Date {
    ISO8601DateFormatter().date(from: s)!
}

private let periodStart = iso("2026-10-01T00:00:00Z")
private let previousStart = iso("2026-09-01T00:00:00Z")

private func cap(limit: UInt64 = 1000, enabled: Bool = true, lastStart: Date? = nil, lastThreshold: Int? = nil) -> Cap {
    Cap(networkID: 1, period: .monthly, limitBytes: limit, enabled: enabled, lastAlertPeriodStart: lastStart, lastAlertThreshold: lastThreshold)
}

@Test func alertsAt80Once() {
    let first = CapEvaluator.evaluate(cap(), used: 810, periodStart: periodStart)
    #expect(first.alert == CapAlert(networkID: 1, period: .monthly, threshold: 80, used: 810, limit: 1000))
    #expect(first.updated.lastAlertThreshold == 80)
    #expect(first.updated.lastAlertPeriodStart == periodStart)
    let second = CapEvaluator.evaluate(first.updated, used: 850, periodStart: periodStart)
    #expect(second.alert == nil)
    #expect(second.updated == first.updated)
    let third = CapEvaluator.evaluate(second.updated, used: 1000, periodStart: periodStart)
    #expect(third.alert?.threshold == 100)
}

@Test func belowThresholdDoesNothing() {
    let r = CapEvaluator.evaluate(cap(), used: 799, periodStart: periodStart)
    #expect(r.alert == nil)
    #expect(r.updated == cap())
}

@Test func jumpStraightTo100SendsOnly100() {
    let r = CapEvaluator.evaluate(cap(), used: 1200, periodStart: periodStart)
    #expect(r.alert?.threshold == 100)
    #expect(r.updated.lastAlertThreshold == 100)
    #expect(CapEvaluator.evaluate(r.updated, used: 1500, periodStart: periodStart).alert == nil)
}

@Test func newPeriodRearms() {
    let old = cap(lastStart: previousStart, lastThreshold: 100)
    let r = CapEvaluator.evaluate(old, used: 810, periodStart: periodStart)
    #expect(r.alert?.threshold == 80)
    #expect(r.updated.lastAlertPeriodStart == periodStart)
    #expect(r.updated.lastAlertThreshold == 80)
}

@Test func disabledNeverAlerts() {
    let c = cap(enabled: false)
    let r = CapEvaluator.evaluate(c, used: 5000, periodStart: periodStart)
    #expect(r.alert == nil)
    #expect(r.updated == c)
}

@Test func zeroLimitNeverAlerts() {
    let r = CapEvaluator.evaluate(cap(limit: 0), used: 5000, periodStart: periodStart)
    #expect(r.alert == nil)
    #expect(CapEvaluator.level(used: 5000, limit: 0) == .normal)
}

@Test func hugeValuesDoNotOverflow() {
    let r = CapEvaluator.evaluate(cap(limit: UInt64.max), used: UInt64.max, periodStart: periodStart)
    #expect(r.alert?.threshold == 100)
    let below = CapEvaluator.evaluate(cap(limit: UInt64.max), used: UInt64.max / 100 * 79, periodStart: periodStart)
    #expect(below.alert == nil)
}

@Test func levels() {
    #expect(CapEvaluator.level(used: 799, limit: 1000) == .normal)
    #expect(CapEvaluator.level(used: 800, limit: 1000) == .warning)
    #expect(CapEvaluator.level(used: 999, limit: 1000) == .warning)
    #expect(CapEvaluator.level(used: 1000, limit: 1000) == .exceeded)
}

@Test func dailyUsesCalendarDay_monthlyUsesBillingDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    let boundaries = PeriodBoundaries(calendar: calendar)
    let now = iso("2026-10-28T10:00:00+05:30")

    let daily = CapEvaluator.periodInterval(Cap(networkID: 1, period: .daily, limitBytes: 1, enabled: true), billingDay: 15, now: now, boundaries: boundaries)
    #expect(daily == boundaries.interval(.day, containing: now))
    #expect(daily.start == iso("2026-10-28T00:00:00+05:30"))

    let monthly = CapEvaluator.periodInterval(cap(), billingDay: 15, now: now, boundaries: boundaries)
    #expect(monthly.start == iso("2026-10-15T00:00:00+05:30"))
    #expect(monthly.end == iso("2026-11-15T00:00:00+05:30"))
}
