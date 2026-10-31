import Foundation
import Testing
@testable import NetPulseCore

private let home = NetworkKey(fingerprint: "wifi:ssid:Home", kind: .wifi, suggestedName: "Home")
private let hotspot = NetworkKey(fingerprint: "wifi:ssid:Hotspot", kind: .wifi, suggestedName: "Hotspot")

private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private func delta(_ rx: UInt64, _ tx: UInt64) -> InterfaceDelta {
    InterfaceDelta(name: "en0", kind: .wifi, rx: rx, tx: tx)
}

private func app(_ key: String, name: String = "App") -> AppIdentity {
    AppIdentity(key: key, bundleID: key, displayName: name, bundlePath: nil, group: .app)
}

private func sample(_ bytesIn: UInt64, _ bytesOut: UInt64) -> ProcessSample {
    ProcessSample(pid: 1, truncatedName: "x", bytesIn: bytesIn, bytesOut: bytesOut)
}

@Test func mergesIntoFifteenMinuteBuckets() {
    var acc = UsageAccumulator()
    acc.addInterface([delta(100, 10)], networkFor: { _ in home }, at: date("2026-10-28T10:01:00Z"))
    acc.addInterface([delta(50, 5)], networkFor: { _ in home }, at: date("2026-10-28T10:14:59Z"))
    acc.addInterface([delta(7, 3)], networkFor: { _ in home }, at: date("2026-10-28T10:15:00Z"))
    let rows = acc.drain()
    let first = PeriodBoundaries.bucketStart(date("2026-10-28T10:00:00Z"))
    #expect(rows.count == 2)
    #expect(rows[0].bucketStart == first)
    #expect(rows[0].down == 150)
    #expect(rows[0].up == 15)
    #expect(rows[1].bucketStart == first + 900)
    #expect(rows[1].down == 7)
    #expect(rows[1].up == 3)
    #expect(rows.allSatisfy { $0.app == nil && $0.network == home })
}

@Test func appAndTotalRowsSeparate() {
    var acc = UsageAccumulator()
    let t = date("2026-10-28T10:01:00Z")
    acc.addInterface([delta(1000, 100)], networkFor: { _ in home }, at: t)
    acc.addApps([(sample(600, 60), app("a")), (sample(300, 30), app("b"))], network: home, at: t)
    let rows = acc.drain()
    #expect(rows.count == 3)
    #expect(rows[0].app == nil)
    #expect(rows[0].down == 1000)
    #expect(rows[0].up == 100)
    #expect(rows[1].app?.key == "a")
    #expect(rows[1].down == 600)
    #expect(rows[1].up == 60)
    #expect(rows[2].app?.key == "b")
    #expect(rows[2].down == 300)
    #expect(rows[2].up == 30)
}

@Test func switchAttributesToNetworkAtSampleTime() {
    var acc = UsageAccumulator()
    let t1 = date("2026-10-28T10:01:00Z")
    let t2 = date("2026-10-28T10:02:00Z")
    acc.addInterface([delta(100, 10)], networkFor: { _ in home }, at: t1)
    acc.addInterface([delta(40, 4)], networkFor: { _ in hotspot }, at: t2)
    let rows = acc.drain()
    #expect(rows.count == 2)
    let homeRow = rows.first { $0.network == home }
    let hotspotRow = rows.first { $0.network == hotspot }
    #expect(homeRow?.down == 100)
    #expect(homeRow?.up == 10)
    #expect(hotspotRow?.down == 40)
    #expect(hotspotRow?.up == 4)
}

@Test func drainEmpties() {
    var acc = UsageAccumulator()
    acc.addInterface([delta(1, 1)], networkFor: { _ in home }, at: date("2026-10-28T10:01:00Z"))
    #expect(acc.drain().count == 1)
    #expect(acc.drain().isEmpty)
}

@Test func zeroSamplesDropped() {
    var acc = UsageAccumulator()
    let t = date("2026-10-28T10:01:00Z")
    acc.addApps([(sample(0, 0), app("a"))], network: home, at: t)
    acc.addInterface([delta(0, 0)], networkFor: { _ in home }, at: t)
    #expect(acc.drain().isEmpty)
}

@Test func appRowsKeepLatestMetadata() {
    var acc = UsageAccumulator()
    let t = date("2026-10-28T10:01:00Z")
    acc.addApps([(sample(10, 1), app("a", name: "Old"))], network: home, at: t)
    acc.addApps([(sample(5, 2), app("a", name: "New"))], network: home, at: t)
    let rows = acc.drain()
    #expect(rows.count == 1)
    #expect(rows[0].app?.displayName == "New")
    #expect(rows[0].down == 15)
    #expect(rows[0].up == 3)
}

@Test func additionSaturates() {
    var acc = UsageAccumulator()
    let t = date("2026-10-28T10:01:00Z")
    acc.addInterface([delta(UInt64.max - 1, 1)], networkFor: { _ in home }, at: t)
    acc.addInterface([delta(10, 1)], networkFor: { _ in home }, at: t)
    let rows = acc.drain()
    #expect(rows[0].down == UInt64.max)
    #expect(rows[0].up == 2)
}

@Test func drainOrderIsDeterministic() {
    var acc = UsageAccumulator()
    let early = date("2026-10-28T10:01:00Z")
    let late = date("2026-10-28T10:16:00Z")
    acc.addApps([(sample(1, 1), app("z")), (sample(1, 1), app("a"))], network: hotspot, at: late)
    acc.addApps([(sample(1, 1), app("b"))], network: home, at: early)
    acc.addInterface([delta(1, 1)], networkFor: { _ in hotspot }, at: late)
    acc.addInterface([delta(1, 1)], networkFor: { _ in home }, at: early)
    let rows = acc.drain()
    let order = rows.map { "\($0.bucketStart)|\($0.network.fingerprint)|\($0.app?.key ?? "")" }
    #expect(order == order.sorted())
    #expect(rows[0].app == nil)
    #expect(rows.last?.app?.key == "z")
}

@Test func unknownWiFiConstant() {
    #expect(UsageAccumulator.unknownWiFi.fingerprint == "wifi:unknown")
    #expect(UsageAccumulator.unknownWiFi.kind == .wifi)
    #expect(UsageAccumulator.unknownWiFi.suggestedName == "Wi-Fi")
}
