import Testing
@testable import NetPulseCore

private func en0(_ rx: UInt64, _ tx: UInt64) -> InterfaceCounter {
    InterfaceCounter(name: "en0", kind: .wifi, rxBytes: rx, txBytes: tx, isUp: true)
}
private func en5(_ rx: UInt64, _ tx: UInt64) -> InterfaceCounter {
    InterfaceCounter(name: "en5", kind: .ethernet, rxBytes: rx, txBytes: tx, isUp: true)
}
private func lo0(_ rx: UInt64, _ tx: UInt64) -> InterfaceCounter {
    InterfaceCounter(name: "lo0", kind: .loopback, rxBytes: rx, txBytes: tx, isUp: true)
}
private func utun0(_ rx: UInt64, _ tx: UInt64) -> InterfaceCounter {
    InterfaceCounter(name: "utun0", kind: .virtual, rxBytes: rx, txBytes: tx, isUp: true)
}

@Test func firstIngestIsBaseline() {
    var t = DeltaTracker()
    let r = t.ingest([en0(100, 50)])
    #expect(r.deltas.isEmpty)
    #expect(r.discontinuities.isEmpty)
}

@Test func normalDelta() {
    var t = DeltaTracker()
    _ = t.ingest([en0(100, 50)])
    #expect(t.ingest([en0(150, 70)]).deltas == [.init(name: "en0", kind: .wifi, rx: 50, tx: 20)])
}

@Test func counterDropIsResetNotNegative() {
    var t = DeltaTracker()
    _ = t.ingest([en0(1_000, 1_000)])
    let r = t.ingest([en0(10, 5)])
    #expect(r.deltas.isEmpty)
    #expect(r.discontinuities == [.counterReset("en0")])
    #expect(t.ingest([en0(20, 9)]).deltas.first?.rx == 10)
}

@Test func txOnlyDropIsReset() {
    var t = DeltaTracker()
    _ = t.ingest([en0(100, 100)])
    let r = t.ingest([en0(200, 5)])
    #expect(r.deltas.isEmpty)
    #expect(r.discontinuities == [.counterReset("en0")])
}

@Test func reappearingInterfaceIsBaseline() {
    var t = DeltaTracker()
    _ = t.ingest([en0(100, 50)])
    let gone = t.ingest([])
    #expect(gone.deltas.isEmpty)
    #expect(gone.discontinuities == [.disappeared("en0")])
    let back = t.ingest([en0(9_000, 4_000)])
    #expect(back.deltas.isEmpty)
    #expect(back.discontinuities == [.appeared("en0")])
    #expect(t.ingest([en0(9_100, 4_010)]).deltas == [.init(name: "en0", kind: .wifi, rx: 100, tx: 10)])
}

@Test func newInterfaceAfterFirstIngestAppearsAndIsOrdered() {
    var t = DeltaTracker()
    _ = t.ingest([en0(100, 50)])
    let r = t.ingest([en5(500, 500), en0(110, 60)])
    #expect(r.deltas == [.init(name: "en0", kind: .wifi, rx: 10, tx: 10)])
    #expect(r.discontinuities == [.appeared("en5")])
}

@Test func loopbackAndVirtualIgnored() {
    var t = DeltaTracker()
    let gb: UInt64 = 1_000_000_000
    _ = t.ingest([en0(0, 0), lo0(0, 0), utun0(0, 0)])
    let r = t.ingest([en0(10, 5), lo0(gb, gb), utun0(gb, gb)])
    #expect(r.deltas == [.init(name: "en0", kind: .wifi, rx: 10, tx: 5)])
    #expect(r.discontinuities.isEmpty)
}

@Test func wakeResetProducesNoDelta() {
    var t = DeltaTracker()
    _ = t.ingest([en0(0, 0)])
    t.reset()
    let r = t.ingest([en0(5_000_000_000, 0)])
    #expect(r.deltas.isEmpty)
    #expect(r.discontinuities.isEmpty)
}

@Test func speedUsesMonotonicElapsed() {
    var s = SpeedCalculator()
    let t0 = ContinuousClock.now
    _ = s.update(totalRx: 0, totalTx: 0, at: t0)
    let v = s.update(totalRx: 2_000_000, totalTx: 500_000, at: t0.advanced(by: .seconds(2)))
    #expect(v == Speed(down: 1_000_000, up: 250_000))
}

@Test func speedFirstUpdateIsZero() {
    var s = SpeedCalculator()
    #expect(s.update(totalRx: 5, totalTx: 5, at: .now) == .zero)
}

@Test func speedZeroElapsedOrDropIsZero() {
    var s = SpeedCalculator()
    let t0 = ContinuousClock.now
    _ = s.update(totalRx: 1_000, totalTx: 1_000, at: t0)
    #expect(s.update(totalRx: 9_000, totalTx: 9_000, at: t0) == .zero)
    #expect(s.update(totalRx: 3_000, totalTx: 1_000, at: t0.advanced(by: .seconds(1))) == Speed(down: 2_000, up: 0))
    #expect(s.update(totalRx: 10, totalTx: 1_000, at: t0.advanced(by: .seconds(2))) == .zero)
    #expect(s.update(totalRx: 110, totalTx: 1_500, at: t0.advanced(by: .seconds(3))) == Speed(down: 100, up: 500))
}
