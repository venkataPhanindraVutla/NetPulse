import Foundation
import Testing
@testable import NetPulseCore

private let home = NetworkKey(fingerprint: "wifi:ssid:Home", kind: .wifi, suggestedName: "Home")
private let hotspot = NetworkKey(fingerprint: "wifi:ssid:Hotspot", kind: .wifi, suggestedName: "Hotspot")
private let safari = AppIdentity(key: "com.apple.Safari", bundleID: "com.apple.Safari", displayName: "Safari", bundlePath: "/Applications/Safari.app", group: .app)

private func tempPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("usage.sqlite").path
}

private func cleanup(_ path: String) {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

private func row(_ bucket: Int64, _ net: NetworkKey, _ app: AppIdentity?, _ down: UInt64, _ up: UInt64) -> UsageRow {
    UsageRow(bucketStart: bucket, network: net, app: app, down: down, up: up)
}

private let wide = DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 4_000_000_000))

@Test func upsertAdds() async throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try UsageStore(path: path)
    try await store.write([row(900, home, nil, 100, 10)])
    try await store.write([row(900, home, nil, 50, 5)])
    #expect(try await store.totals(network: nil, in: wide) == Totals(down: 150, up: 15))
}

@Test func survivesReopen() async throws {
    let path = tempPath()
    defer { cleanup(path) }
    do {
        let store = try UsageStore(path: path)
        try await store.write([row(900, home, nil, 100, 10), row(900, home, safari, 40, 4)])
    }
    let reopened = try UsageStore(path: path)
    #expect(try await reopened.totals(network: nil, in: wide) == Totals(down: 100, up: 10))
    #expect(try await reopened.appUsage(network: nil, in: wide).first?.id == "com.apple.Safari")
}

@Test func otherIsPerNetworkAndFloored() async throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try UsageStore(path: path)
    try await store.write([
        row(900, home, nil, 1000, 0), row(900, home, safari, 900, 0),
        row(900, hotspot, nil, 100, 0), row(900, hotspot, safari, 300, 0),
    ])
    let usage = try await store.appUsage(network: nil, in: wide)
    #expect(usage.last?.id == "other")
    #expect(usage.last?.down == 100)
    #expect(usage.first?.down == 1200)
}

@Test func otherOmittedWhenZeroAndSortedLast() async throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try UsageStore(path: path)
    try await store.write([row(900, home, nil, 100, 0), row(900, home, safari, 100, 0)])
    #expect(try await store.appUsage(network: nil, in: wide).map(\.id) == ["com.apple.Safari"])
}

@Test func totalsInvariantAcrossTimeZones() async throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try UsageStore(path: path)
    let start: Int64 = 1_767_225_600
    var rows: [UsageRow] = []
    for i in 0..<(3 * 96) {
        rows.append(row(start + Int64(i) * 900, home, nil, UInt64(i + 1), UInt64(i)))
    }
    try await store.write(rows)
    let interval = DateInterval(start: Date(timeIntervalSince1970: TimeInterval(start)), end: Date(timeIntervalSince1970: TimeInterval(start + 3 * 86_400)))
    var ist = Calendar(identifier: .gregorian)
    ist.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    var pst = Calendar(identifier: .gregorian)
    pst.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    let expected = try await store.totals(network: nil, in: interval)
    for calendar in [ist, pst] {
        let days = try await store.daily(network: nil, in: interval, calendar: calendar)
        #expect(days.map(\.totals.down).reduce(0, +) == expected.down)
        #expect(days.map(\.totals.up).reduce(0, +) == expected.up)
    }
    #expect(expected.down > 0)

    // One bucket at 2026-01-01 20:00 UTC: 01:30 on Jan 2 in IST, 12:00 on Jan 1 in PST.
    let lone = try UsageStore(path: ":memory:")
    let evening: Int64 = 1_767_225_600 + 20 * 3600
    try await lone.write([row(evening, home, nil, 500, 50)])
    let span = DateInterval(start: Date(timeIntervalSince1970: TimeInterval(evening - 2 * 86_400)), end: Date(timeIntervalSince1970: TimeInterval(evening + 2 * 86_400)))
    let istDays = try await lone.daily(network: nil, in: span, calendar: ist).filter { $0.totals.down > 0 }
    let pstDays = try await lone.daily(network: nil, in: span, calendar: pst).filter { $0.totals.down > 0 }
    #expect(istDays.map { ist.dateComponents([.year, .month, .day], from: $0.id) } == [DateComponents(year: 2026, month: 1, day: 2)])
    #expect(pstDays.map { pst.dateComponents([.year, .month, .day], from: $0.id) } == [DateComponents(year: 2026, month: 1, day: 1)])
    #expect(istDays.first?.totals == Totals(down: 500, up: 50))
}

@Test func dailyMarksGaps() async throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try UsageStore(path: path)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let start = Date(timeIntervalSince1970: 1_767_225_600)
    let interval = DateInterval(start: start, end: start.addingTimeInterval(3 * 86_400))
    try await store.recordGap(start: start.addingTimeInterval(86_400 + 3600), end: start.addingTimeInterval(86_400 + 7200), reason: "not running")
    let days = try await store.daily(network: nil, in: interval, calendar: utc)
    #expect(days.count == 3)
    #expect(days.map(\.hasGap) == [false, true, false])
}

@Test func onlyNotRunningAndPausedGapsMarkDays() async throws {
    let store = try UsageStore(path: ":memory:")
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let start = Date(timeIntervalSince1970: 1_767_225_600)
    let interval = DateInterval(start: start, end: start.addingTimeInterval(4 * 86_400))
    for (day, reason) in [(0, "sleep"), (1, "paused"), (2, "nettop exited"), (2, "nettop split"), (3, "not running")] {
        let at = start.addingTimeInterval(Double(day) * 86_400 + 3600)
        try await store.recordGap(start: at, end: at.addingTimeInterval(600), reason: reason)
    }
    let days = try await store.daily(network: nil, in: interval, calendar: utc)
    #expect(days.map(\.hasGap) == [false, true, false, true])
    #expect(try await store.gaps().count == 5)
}

@Test func heartbeatRoundTrips() async throws {
    let path = tempPath()
    defer { cleanup(path) }
    let at = Date(timeIntervalSince1970: 1_790_000_123)
    do {
        let store = try UsageStore(path: path)
        #expect(try await store.heartbeat() == nil)
        try await store.setHeartbeat(at.addingTimeInterval(-50))
        try await store.setHeartbeat(at)
    }
    #expect(try await UsageStore(path: path).heartbeat() == at)
}

@Test func renameNotOverwrittenByWrite() async throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try UsageStore(path: path)
    try await store.write([row(900, home, nil, 1, 1)])
    let id = try #require(try await store.networks().first?.id)
    try await store.updateNetwork(id: id, displayName: "Phone hotspot", billingDay: 5)
    try await store.write([row(1800, home, nil, 1, 1)])
    let network = try #require(try await store.networks().first)
    #expect(network.displayName == "Phone hotspot")
    #expect(network.billingDay == 5)
}

@Test func capsRoundTrip() async throws {
    let path = tempPath()
    defer { cleanup(path) }
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    do {
        let store = try UsageStore(path: path)
        #expect(try await store.caps().isEmpty)
        try await store.saveCap(Cap(networkID: 1, period: .monthly, limitBytes: 5_000_000_000, enabled: true))
        try await store.saveCap(Cap(networkID: 1, period: .daily, limitBytes: 100, enabled: false))
        var caps = try await store.caps()
        #expect(caps.count == 2)
        let monthly = try #require(caps.first { $0.period == .monthly })
        #expect(monthly.limitBytes == 5_000_000_000)
        #expect(monthly.lastAlertPeriodStart == nil)
        #expect(monthly.lastAlertThreshold == nil)

        var updated = monthly
        updated.limitBytes = UInt64.max
        updated.lastAlertPeriodStart = start
        updated.lastAlertThreshold = 80
        try await store.saveCap(updated)
        caps = try await store.caps()
        #expect(caps.count == 2)
    }
    let reopened = try UsageStore(path: path)
    let caps = try await reopened.caps()
    #expect(caps.count == 2)
    let monthly = try #require(caps.first { $0.period == .monthly })
    #expect(monthly.limitBytes == UInt64(Int64.max))
    #expect(monthly.lastAlertPeriodStart == start)
    #expect(monthly.lastAlertThreshold == 80)
    #expect(monthly.enabled)
    let daily = try #require(caps.first { $0.period == .daily })
    #expect(!daily.enabled)
}

@Test func capAlertStateUpdateLeavesLimitAndEnabledAlone() async throws {
    let store = try UsageStore(path: ":memory:")
    try await store.saveCap(Cap(networkID: 1, period: .monthly, limitBytes: 5_000_000_000, enabled: true))
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    try await store.updateCapAlertState(networkID: 1, period: .monthly, lastAlertPeriodStart: start, lastAlertThreshold: 80)
    var cap = try #require(try await store.caps().first)
    #expect(cap.limitBytes == 5_000_000_000 && cap.enabled)
    #expect(cap.lastAlertPeriodStart == start && cap.lastAlertThreshold == 80)
    try await store.saveCap(Cap(networkID: 1, period: .monthly, limitBytes: 7_000_000_000, enabled: false))
    try await store.updateCapAlertState(networkID: 1, period: .monthly, lastAlertPeriodStart: start, lastAlertThreshold: 100)
    cap = try #require(try await store.caps().first)
    #expect(cap.limitBytes == 7_000_000_000 && !cap.enabled && cap.lastAlertThreshold == 100)
}

private let homeByGateway = NetworkKey(fingerprint: "wifi:gw:aa:bb:cc:00:11:22", kind: .wifi, suggestedName: "Wi-Fi network")

private func networkID(_ store: UsageStore, _ key: NetworkKey) async throws -> Int64? {
    try await store.networks().first { $0.key.fingerprint == key.fingerprint }?.id
}

@Test func mergeNetworkMovesUsageAndAddsOnConflict() async throws {
    let store = try UsageStore(path: ":memory:")
    try await store.write([
        row(900, homeByGateway, nil, 100, 10), row(900, homeByGateway, safari, 60, 6), row(1800, homeByGateway, nil, 7, 1),
        row(900, home, nil, 1000, 100), row(900, home, safari, 500, 50), row(2700, home, nil, 3, 3),
    ])
    let before = try await store.totals(network: nil, in: wide)
    try await store.mergeNetwork(from: homeByGateway, into: home)
    #expect(try await store.networks().map(\.key.fingerprint) == [home.fingerprint])
    let homeID = try #require(try await networkID(store, home))
    #expect(try await store.totals(network: homeID, in: wide) == before)
    #expect(try await store.totals(network: homeID, in: DateInterval(start: Date(timeIntervalSince1970: 900), duration: 900)) == Totals(down: 1100, up: 110))
    let apps = try await store.appUsage(network: homeID, in: wide)
    #expect(apps.first { $0.id == safari.key }?.down == 560)
}

@Test func mergeNetworkCreatesTargetAndIsIdempotent() async throws {
    let store = try UsageStore(path: ":memory:")
    try await store.write([row(900, homeByGateway, nil, 100, 10)])
    try await store.mergeNetwork(from: homeByGateway, into: home)
    try await store.mergeNetwork(from: homeByGateway, into: home)
    try await store.mergeNetwork(from: home, into: home)
    let networks = try await store.networks()
    #expect(networks.map(\.key.fingerprint) == [home.fingerprint])
    #expect(networks.first?.displayName == "Home")
    #expect(try await store.totals(network: networks.first?.id, in: wide) == Totals(down: 100, up: 10))
}

@Test func mergeNetworkMovesCapsOnlyWhereTargetHasNone() async throws {
    let store = try UsageStore(path: ":memory:")
    try await store.write([row(900, homeByGateway, nil, 1, 1), row(900, home, nil, 1, 1)])
    let gwID = try #require(try await networkID(store, homeByGateway))
    let homeID = try #require(try await networkID(store, home))
    try await store.saveCap(Cap(networkID: gwID, period: .monthly, limitBytes: 50, enabled: true))
    try await store.saveCap(Cap(networkID: gwID, period: .daily, limitBytes: 5, enabled: true))
    try await store.saveCap(Cap(networkID: homeID, period: .daily, limitBytes: 9, enabled: false))
    try await store.mergeNetwork(from: homeByGateway, into: home)
    let caps = try await store.caps()
    #expect(caps.count == 2)
    #expect(caps.allSatisfy { $0.networkID == homeID })
    #expect(caps.first { $0.period == .monthly }?.limitBytes == 50)
    let daily = try #require(caps.first { $0.period == .daily })
    #expect(daily.limitBytes == 9 && !daily.enabled)
}

@Test func mergeNetworkCarriesRenameOnlyOntoDefaultName() async throws {
    let store = try UsageStore(path: ":memory:")
    try await store.write([row(900, homeByGateway, nil, 1, 1), row(900, home, nil, 1, 1)])
    let gwID = try #require(try await networkID(store, homeByGateway))
    try await store.updateNetwork(id: gwID, displayName: "Flat", billingDay: 12)
    try await store.mergeNetwork(from: homeByGateway, into: home)
    var merged = try #require(try await store.networks().first)
    #expect(merged.displayName == "Flat")
    #expect(merged.billingDay == 12)

    try await store.write([row(900, homeByGateway, nil, 1, 1)])
    let newGwID = try #require(try await networkID(store, homeByGateway))
    try await store.updateNetwork(id: newGwID, displayName: "Other name", billingDay: 3)
    try await store.updateNetwork(id: merged.id, displayName: "Home office", billingDay: 20)
    try await store.mergeNetwork(from: homeByGateway, into: home)
    merged = try #require(try await store.networks().first)
    #expect(merged.displayName == "Home office")
    #expect(merged.billingDay == 20)
}

@Test func mergeNetworkKeepsDefaultNameWhenSourceNotRenamed() async throws {
    let store = try UsageStore(path: ":memory:")
    try await store.write([row(900, homeByGateway, nil, 1, 1), row(900, home, nil, 1, 1)])
    try await store.mergeNetwork(from: homeByGateway, into: home)
    #expect(try await store.networks().first?.displayName == "Home")
}
