import Foundation
import Testing
@testable import NetPulseCore

private func iso(_ s: String) -> Date {
    ISO8601DateFormatter().date(from: s)!
}

private func calendar(_ id: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: id)!
    c.firstWeekday = 2
    return c
}

private let ist = calendar("Asia/Kolkata")
private let ny = calendar("America/New_York")

@Test func istDayBoundary() {
    let d = iso("2026-10-28T00:10:00+05:30")
    let i = PeriodBoundaries(calendar: ist).interval(.day, containing: d)
    #expect(i.start == iso("2026-10-28T00:00:00+05:30"))
    #expect(i.duration == 86_400)
}

@Test func dstDayIs23Hours() {
    let i = PeriodBoundaries(calendar: ny).interval(.day, containing: iso("2026-03-08T12:00:00-04:00"))
    #expect(i.duration == 82_800)
}

@Test func weekStartsOnMonday() {
    let i = PeriodBoundaries(calendar: ist).interval(.week, containing: iso("2026-10-28T10:00:00+05:30"))
    #expect(i.start == iso("2026-10-26T00:00:00+05:30"))
    #expect(i.end == iso("2026-11-02T00:00:00+05:30"))
}

@Test func billingDay15() {
    let b = PeriodBoundaries(calendar: ist)
    #expect(b.billingMonth(containing: iso("2026-10-14T10:00:00+05:30"), billingDay: 15).start == iso("2026-09-15T00:00:00+05:30"))
    #expect(b.billingMonth(containing: iso("2026-10-15T00:00:00+05:30"), billingDay: 15).start == iso("2026-10-15T00:00:00+05:30"))
    #expect(b.billingMonth(containing: iso("2026-10-15T00:00:00+05:30"), billingDay: 15).end == iso("2026-11-15T00:00:00+05:30"))
}

@Test func billingDayClampedTo28() {
    let b = PeriodBoundaries(calendar: ist)
    let i = b.billingMonth(containing: iso("2026-10-30T10:00:00+05:30"), billingDay: 31)
    #expect(i.start == iso("2026-10-28T00:00:00+05:30"))
    let j = b.billingMonth(containing: iso("2026-10-30T10:00:00+05:30"), billingDay: 0)
    #expect(j.start == iso("2026-10-01T00:00:00+05:30"))
}

@Test func billingDay1EqualsCalendarMonth() {
    let b = PeriodBoundaries(calendar: ist)
    for s in ["2026-10-28T10:00:00+05:30", "2026-02-01T00:00:00+05:30", "2026-12-31T23:59:00+05:30"] {
        let d = iso(s)
        #expect(b.billingMonth(containing: d, billingDay: 1) == b.interval(.month, containing: d))
    }
}

@Test func bucketStartFloorsTo900() {
    #expect(PeriodBoundaries.bucketStart(Date(timeIntervalSince1970: 1_793_125_799)) == 1_793_124_900)
}

@Test func billingMonthCrossesYearBoundary() {
    let i = PeriodBoundaries(calendar: ist).billingMonth(containing: iso("2026-01-10T10:00:00+05:30"), billingDay: 15)
    #expect(i.start == iso("2025-12-15T00:00:00+05:30"))
    #expect(i.end == iso("2026-01-15T00:00:00+05:30"))
}

@Test func everyBucketFitsInsideOneLocalDay() {
    let cases: [(Calendar, String, TimeInterval)] = [
        (ist, "2026-10-28T12:00:00Z", 86_400),
        (calendar("Asia/Kathmandu"), "2026-10-28T12:00:00Z", 86_400),
        (ny, "2026-10-28T12:00:00Z", 86_400),
        (ny, "2026-03-08T12:00:00Z", 82_800),
        (ny, "2026-11-01T12:00:00Z", 90_000),
    ]
    for (cal, s, duration) in cases {
        let b = PeriodBoundaries(calendar: cal)
        let day = b.interval(.day, containing: iso(s))
        #expect(day.duration == duration)
        #expect(PeriodBoundaries.bucketStart(day.start) == Int64(day.start.timeIntervalSince1970))
        var t = Int64(day.start.timeIntervalSince1970)
        while t < Int64(day.end.timeIntervalSince1970) {
            let start = Date(timeIntervalSince1970: TimeInterval(t))
            let end = start.addingTimeInterval(900)
            #expect(end <= day.end)
            #expect(b.interval(.day, containing: start) == day)
            #expect(b.interval(.day, containing: end.addingTimeInterval(-1)) == day)
            t += 900
        }
    }
}
