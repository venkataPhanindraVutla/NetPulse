import Foundation
import Testing
@testable import NetPulseCore

private let header = ",bytes_in,bytes_out,"
private let baseDate = Date(timeIntervalSince1970: 1_793_361_600)

private struct ReadFailure: Error {}

private final class FakeReader: InterfaceCounterReading, @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [String: InterfaceCounter] = [:]
    private var failing = false

    func setFailing(_ value: Bool) { lock.withLock { failing = value } }

    func add(_ name: String, kind: InterfaceKind, rx: UInt64 = 0, tx: UInt64 = 0) {
        lock.withLock {
            let old = counters[name]
            counters[name] = InterfaceCounter(
                name: name, kind: kind,
                rxBytes: (old?.rxBytes ?? 0) + rx, txBytes: (old?.txBytes ?? 0) + tx, isUp: true)
        }
    }

    func read() throws -> [InterfaceCounter] {
        try lock.withLock {
            if failing { throw ReadFailure() }
            return counters.values.sorted { $0.name < $1.name }
        }
    }
}

private final class FakeDetector: NetworkDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var primaryObservation: NetworkObservation?
    private var active: [NetworkObservation]
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(primary: NetworkObservation?, active: [NetworkObservation]? = nil) {
        primaryObservation = primary
        self.active = active ?? primary.map { [$0] } ?? []
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func set(primary: NetworkObservation?, active: [NetworkObservation]) {
        lock.withLock {
            primaryObservation = primary
            self.active = active
        }
    }

    func primary() -> NetworkObservation? { lock.withLock { primaryObservation } }
    func activePhysical() -> [NetworkObservation] { lock.withLock { active } }
    func changes() -> AsyncStream<Void> { stream }
    func emitChange() { continuation.yield() }
}

private func wifi(_ ssid: String?, name: String = "en0", gateway: String? = nil) -> NetworkObservation {
    NetworkObservation(interfaceName: name, kind: .wifi, ssid: ssid, gatewayMAC: gateway, interfaceMAC: "aa:aa:aa:aa:aa:01")
}

private func ethernet(mac: String?, name: String = "en5") -> NetworkObservation {
    NetworkObservation(interfaceName: name, kind: .ethernet, ssid: nil, gatewayMAC: nil, interfaceMAC: mac)
}

private final class FakeLauncher: LineProcessLaunching, @unchecked Sendable {
    typealias Script = @Sendable (_ index: Int, _ filter: String) -> (lines: [String], finish: Bool)

    private let lock = NSLock()
    private let script: Script
    private var argumentLog: [[String]] = []
    private var terminations = 0

    init(script: @escaping Script = { _, _ in ([], false) }) {
        self.script = script
    }

    var arguments: [[String]] { lock.withLock { argumentLog } }
    var terminateCount: Int { lock.withLock { terminations } }
    var filters: [String] { arguments.map(Self.filter) }

    private static func filter(_ arguments: [String]) -> String {
        arguments.indices.filter { arguments[$0] == "-t" && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }.joined(separator: "+")
    }

    func launch(arguments: [String]) throws -> (lines: AsyncStream<String>, terminate: @Sendable () -> Void) {
        let index = lock.withLock { () -> Int in
            argumentLog.append(arguments)
            return argumentLog.count - 1
        }
        let filter = Self.filter(arguments)
        let (lines, finish) = script(index, filter)
        let (stream, continuation) = AsyncStream<String>.makeStream()
        for line in lines { continuation.yield(line) }
        if finish { continuation.finish() }
        return (stream, { [self] in
            lock.withLock { terminations += 1 }
            continuation.finish()
        })
    }
}

private struct NoProcessInfo: ProcessInfoProviding {
    func executablePath(pid: Int32) -> String? { nil }
    func responsiblePID(pid: Int32) -> Int32? { nil }
    func bundleInfo(atPath: String) -> (id: String, name: String)? { nil }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: Duration = .zero
    private var requested: [Duration] = []
    private let baseInstant = ContinuousClock.now

    func advance(_ d: Duration) { lock.withLock { offset += d } }
    var sleeps: [Duration] { lock.withLock { requested } }

    var engineClock: EngineClock {
        EngineClock(
            now: { [self] in
                let c = lock.withLock { offset }.components
                return baseDate.addingTimeInterval(Double(c.seconds) + Double(c.attoseconds) / 1e18)
            },
            instant: { [self] in baseInstant + lock.withLock { offset } },
            sleep: { [self] d in
                lock.withLock { requested.append(d) }
                try? await Task.sleep(for: .seconds(3600))
            }
        )
    }
}

private struct Harness: Sendable {
    let reader = FakeReader()
    let detector: FakeDetector
    let launcher: FakeLauncher
    let clock = TestClock()
    let directory: String
    let store: UsageStore
    let engine: MonitorEngine

    init(
        detector: FakeDetector = FakeDetector(primary: wifi("Home")),
        launcher: FakeLauncher = FakeLauncher(),
        resolver: AppResolver = AppResolver(provider: NoProcessInfo())
    ) throws {
        self.detector = detector
        self.launcher = launcher
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        store = try UsageStore(path: directory + "/usage.sqlite")
        engine = MonitorEngine(
            store: store, reader: reader, detector: detector,
            resolver: resolver, launcher: launcher,
            nettopInterval: 5, clock: clock.engineClock)
    }

    func step(seconds: Int = 1) async {
        clock.advance(.seconds(seconds))
        await engine.tick()
    }

    func totals(network: String? = nil) async throws -> Totals {
        var id: Int64?
        if let network {
            id = try await store.networks().first { $0.key.fingerprint == network }?.id
            if id == nil { return Totals(down: 0, up: 0) }
        }
        return try await store.totals(network: id, in: DateInterval(start: .distantPast, end: .distantFuture))
    }

    func hasGapToday() async throws -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: baseDate)
        let days = try await store.daily(network: nil, in: DateInterval(start: day, duration: 86_400), calendar: calendar)
        return days.first?.hasGap ?? false
    }

    func gapReasons() async throws -> [String] {
        try await store.gaps().map(\.reason)
    }

    func finish() async {
        await engine.pause()
        await engine.flush()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private func eventually(_ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    for _ in 0..<400 {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test(.timeLimit(.minutes(1))) func flushWritesAccumulatedTotals() async throws {
    let h = try Harness()
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    for _ in 0..<3 {
        h.reader.add("en0", kind: .wifi, rx: 1_000_000, tx: 10_000)
        await h.step()
    }
    await h.engine.flush()
    #expect(try await h.totals() == Totals(down: 3_000_000, up: 30_000))
    #expect(try await h.store.networks().map(\.key.fingerprint) == ["wifi:ssid:Home"])
    let snapshot = await h.engine.latestSnapshot
    #expect(snapshot.speed == Speed(down: 1_000_000, up: 10_000))
    #expect(snapshot.state == .monitoring)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func periodicFlushEveryThirtySeconds() async throws {
    let h = try Harness()
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    for _ in 0..<28 {
        h.reader.add("en0", kind: .wifi, rx: 1_000)
        await h.step()
    }
    #expect(try await h.totals() == Totals(down: 0, up: 0))
    h.reader.add("en0", kind: .wifi, rx: 1_000)
    await h.step()
    #expect(try await h.totals() == Totals(down: 29_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func sleepWakeNoSpike() async throws {
    let h = try Harness()
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    #expect(await eventually { h.launcher.filters == ["wifi+wired"] })
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 2_000_000)
    await h.step()
    await h.engine.willSleep()
    #expect(await eventually { h.launcher.terminateCount == 1 })
    h.reader.add("en0", kind: .wifi, rx: 10_000_000_000, tx: 10_000_000_000)
    h.clock.advance(.seconds(3600))
    await h.engine.didWake()
    await h.step()
    #expect(await h.engine.latestSnapshot.speed == .zero)
    await h.engine.flush()
    #expect(try await h.totals() == Totals(down: 2_000_000, up: 0))
    #expect(try await h.gapReasons().contains("sleep"))
    #expect(try await !h.hasGapToday())
    #expect(await eventually { h.launcher.filters == ["wifi+wired", "wifi+wired"] })
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func dualInterfaceSwitchesToSplitStreams() async throws {
    let detector = FakeDetector(primary: wifi("Home"), active: [wifi("Home"), ethernet(mac: "00:11:22:33:44:55")])
    let h = try Harness(detector: detector)
    h.reader.add("en0", kind: .wifi)
    h.reader.add("en5", kind: .ethernet)
    await h.engine.start()
    await h.step()
    #expect(await eventually { h.launcher.filters == ["wifi+wired"] })
    for _ in 0..<2 {
        h.reader.add("en0", kind: .wifi, rx: 10_000)
        h.reader.add("en5", kind: .ethernet, rx: 10_000)
        await h.step()
    }
    #expect(await !h.engine.isSplit)
    h.reader.add("en0", kind: .wifi, rx: 10_000)
    h.reader.add("en5", kind: .ethernet, tx: 10_000)
    await h.step()
    #expect(await h.engine.isSplit)
    #expect(await eventually { Set(h.launcher.filters.dropFirst()) == ["wifi", "wired"] })
    #expect(h.launcher.arguments.dropFirst().allSatisfy { $0.contains("-t") })
    #expect(await eventually { h.launcher.terminateCount >= 1 })
    await h.engine.flush()
    #expect(try await h.gapReasons().contains("nettop split"))
    #expect(try await !h.hasGapToday())
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func splitStreamsMergeBackAfterSixtySeconds() async throws {
    let detector = FakeDetector(primary: wifi("Home"), active: [wifi("Home"), ethernet(mac: "00:11:22:33:44:55")])
    let h = try Harness(detector: detector)
    h.reader.add("en0", kind: .wifi)
    h.reader.add("en5", kind: .ethernet)
    await h.engine.start()
    #expect(await eventually { h.launcher.filters == ["wifi+wired"] })
    await h.step()
    for _ in 0..<3 {
        h.reader.add("en0", kind: .wifi, rx: 10_000)
        h.reader.add("en5", kind: .ethernet, rx: 10_000)
        await h.step()
    }
    #expect(await h.engine.isSplit)
    #expect(await eventually { h.launcher.filters.count == 3 })
    for _ in 0..<59 {
        h.reader.add("en0", kind: .wifi, rx: 1_000)
        await h.step()
    }
    #expect(await h.engine.isSplit)
    h.reader.add("en0", kind: .wifi, rx: 1_000)
    await h.step()
    #expect(await !h.engine.isSplit)
    #expect(await eventually { h.launcher.filters.last == "wifi+wired" && h.launcher.filters.count == 4 })
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func splitStreamsAttributeToTheirInterfaceNetworks() async throws {
    let block = [header, "x.9,1,1,", header, "app.7,4000,40,", header]
    let launcher = FakeLauncher { _, filter in
        switch filter {
        case "wifi": (block.map { $0.replacingOccurrences(of: "app", with: "wifiapp") }, false)
        case "wired": (block.map { $0.replacingOccurrences(of: "app", with: "wiredapp") }, false)
        default: ([], false)
        }
    }
    let detector = FakeDetector(primary: wifi("Home"), active: [wifi("Home"), ethernet(mac: "00:11:22:33:44:55")])
    let h = try Harness(detector: detector, launcher: launcher)
    h.reader.add("en0", kind: .wifi)
    h.reader.add("en5", kind: .ethernet)
    await h.engine.start()
    await h.step()
    for _ in 0..<3 {
        h.reader.add("en0", kind: .wifi, rx: 10_000)
        h.reader.add("en5", kind: .ethernet, rx: 10_000)
        await h.step()
    }
    let wired = "eth:00:11:22:33:44:55"
    #expect(try await eventually {
        await h.engine.flush()
        let ids = try await h.store.networks()
        guard let home = ids.first(where: { $0.key.fingerprint == "wifi:ssid:Home" })?.id,
              let eth = ids.first(where: { $0.key.fingerprint == wired })?.id else { return false }
        let all = DateInterval(start: .distantPast, end: .distantFuture)
        let homeApps = try await h.store.appUsage(network: home, in: all).map(\.id)
        let ethApps = try await h.store.appUsage(network: eth, in: all).map(\.id)
        return homeApps.contains("proc:wifiapp") && ethApps.contains("proc:wiredapp")
            && !homeApps.contains("proc:wiredapp") && !ethApps.contains("proc:wifiapp")
    })
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func pauseStopsCounting() async throws {
    let h = try Harness()
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 1_000_000)
    #expect(await eventually { h.launcher.filters == ["wifi+wired"] })
    await h.step()
    await h.engine.pause()
    let paused = await h.engine.latestSnapshot
    #expect(paused.state == .paused)
    #expect(paused.speed == .zero)
    #expect(await eventually { h.launcher.terminateCount == 1 })
    h.reader.add("en0", kind: .wifi, rx: 5_000_000)
    await h.step()
    #expect(await h.engine.latestSnapshot.state == .paused)
    await h.engine.resume()
    #expect(await h.engine.latestSnapshot.state == .monitoring)
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 1_000_000)
    await h.step()
    await h.engine.flush()
    #expect(try await h.totals() == Totals(down: 2_000_000, up: 0))
    #expect(try await h.hasGapToday())
    #expect(await eventually { h.launcher.filters == ["wifi+wired", "wifi+wired"] })
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func appSamplesGoToPrimaryNetwork() async throws {
    let launcher = FakeLauncher { _, _ in ([header, "x.9,1,1,", header, "curl.42,5000,100,", header], false) }
    let h = try Harness(launcher: launcher)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    #expect(try await eventually {
        await h.engine.flush()
        let usage = try await h.store.appUsage(network: nil, in: DateInterval(start: .distantPast, end: .distantFuture))
        return usage.first { $0.id == "proc:curl" }.map { $0.down == 5000 && $0.up == 100 } ?? false
    })
    #expect(try await h.store.networks().map(\.key.fingerprint) == ["wifi:ssid:Home"])
    #expect(await h.engine.latestSnapshot.appTrackingAvailable)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func gapEventDisablesAppTrackingAndRecordsGap() async throws {
    let launcher = FakeLauncher { index, _ in ([], index == 0) }
    let h = try Harness(launcher: launcher)
    await h.engine.start()
    #expect(await eventually { await !h.engine.latestSnapshot.appTrackingAvailable })
    await h.engine.flush()
    #expect(try await h.gapReasons().contains { $0.hasPrefix("nettop") })
    #expect(try await !h.hasGapToday())
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func slowSamplingUsesFiveSecondTicks() async throws {
    let h = try Harness()
    await h.engine.start()
    #expect(await eventually { h.clock.sleeps.last == .seconds(1) })
    await h.engine.setFastSampling(false)
    #expect(await eventually { h.clock.sleeps.last == .seconds(5) })
    await h.engine.setFastSampling(true)
    #expect(await eventually { h.clock.sleeps.last == .seconds(1) })
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func unkeyedEthernetCountsSpeedOnly() async throws {
    let h = try Harness(detector: FakeDetector(primary: ethernet(mac: nil)))
    h.reader.add("en5", kind: .ethernet)
    await h.engine.start()
    await h.step()
    h.reader.add("en5", kind: .ethernet, rx: 2_000_000)
    await h.step()
    #expect(await h.engine.latestSnapshot.speed == Speed(down: 2_000_000, up: 0))
    await h.engine.flush()
    #expect(try await h.totals() == Totals(down: 0, up: 0))
    #expect(try await h.store.networks().isEmpty)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func unnamedWiFiFallsBackToUnknownWiFi() async throws {
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)))
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 1_000)
    await h.step()
    await h.engine.flush()
    #expect(try await h.totals(network: UsageAccumulator.unknownWiFi.fingerprint) == Totals(down: 1_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func networkChangeReattributesBytes() async throws {
    let h = try Harness()
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 1_000_000)
    await h.step()
    h.detector.set(primary: wifi("Office"), active: [wifi("Office")])
    h.detector.emitChange()
    #expect(await eventually { await h.engine.latestSnapshot.primaryNetwork?.key.fingerprint == "wifi:ssid:Office" })
    h.reader.add("en0", kind: .wifi, rx: 2_000_000)
    await h.step()
    await h.engine.flush()
    #expect(try await h.totals(network: "wifi:ssid:Home") == Totals(down: 1_000_000, up: 0))
    #expect(try await h.totals(network: "wifi:ssid:Office") == Totals(down: 2_000_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func snapshotStreamDeliversLatest() async throws {
    let h = try Harness()
    h.reader.add("en0", kind: .wifi)
    let stream = await h.engine.snapshots()
    var iterator = stream.makeAsyncIterator()
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 3_000)
    await h.step()
    let snapshot = await iterator.next()
    #expect(snapshot?.speed == Speed(down: 3_000, up: 0))
    await h.engine.pause()
    #expect(await iterator.next()?.state == .paused)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func unresolvedPrimaryIsRetriedWithoutChangeEvent() async throws {
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)))
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.detector.set(primary: wifi(nil, gateway: "aa:bb:cc:00:11:22"), active: [wifi(nil, gateway: "aa:bb:cc:00:11:22")])
    for _ in 0..<3 {
        h.reader.add("en0", kind: .wifi, rx: 1_000)
        await h.step()
    }
    h.reader.add("en0", kind: .wifi, rx: 7_000)
    await h.step()
    #expect(await h.engine.latestSnapshot.primaryNetwork?.key.fingerprint == "wifi:gw:aa:bb:cc:00:11:22")
    await h.engine.flush()
    #expect(try await h.totals(network: UsageAccumulator.unknownWiFi.fingerprint) == Totals(down: 0, up: 0))
    #expect(try await h.totals(network: "wifi:gw:aa:bb:cc:00:11:22") == Totals(down: 10_000, up: 0))
    #expect(try await h.store.networks().map(\.key.fingerprint) == ["wifi:gw:aa:bb:cc:00:11:22"])
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func unresolvedPrimaryRetriesStopAfterAMinute() async throws {
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)))
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    for _ in 0..<61 { await h.step() }
    h.detector.set(primary: wifi("Home"), active: [wifi("Home")])
    for _ in 0..<10 { await h.step() }
    #expect(await h.engine.latestSnapshot.primaryNetwork?.key.fingerprint == UsageAccumulator.unknownWiFi.fingerprint)
    h.detector.emitChange()
    #expect(await eventually { await h.engine.latestSnapshot.primaryNetwork?.key.fingerprint == "wifi:ssid:Home" })
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func parkedTrafficFallsBackToUnknownWiFiWhenRetryWindowExpires() async throws {
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)))
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    for _ in 0..<58 {
        h.reader.add("en0", kind: .wifi, rx: 1_000)
        await h.step()
    }
    #expect(try await h.totals() == Totals(down: 0, up: 0))
    #expect(try await h.store.networks().isEmpty)
    #expect(await h.engine.latestSnapshot.primaryNetwork == nil)
    h.reader.add("en0", kind: .wifi, rx: 1_000)
    await h.step()
    #expect(try await h.totals(network: UsageAccumulator.unknownWiFi.fingerprint) == Totals(down: 59_000, up: 0))
    #expect(await h.engine.latestSnapshot.primaryNetwork?.key == UsageAccumulator.unknownWiFi)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func flushDuringRetryWindowCommitsParkedToUnknownWiFi() async throws {
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)))
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 5_000)
    await h.step()
    await h.engine.flush()
    #expect(try await h.totals(network: UsageAccumulator.unknownWiFi.fingerprint) == Totals(down: 5_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func pauseDuringRetryWindowCommitsParkedToUnknownWiFi() async throws {
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)))
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 4_000)
    await h.step()
    await h.engine.pause()
    await h.engine.flush()
    #expect(try await h.totals(network: UsageAccumulator.unknownWiFi.fingerprint) == Totals(down: 4_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func parkedAppSamplesAreRekeyedOnResolution() async throws {
    let launcher = FakeLauncher { _, _ in ([header, "x.9,1,1,", header, "curl.42,5000,100,", header], false) }
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)), launcher: launcher)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    #expect(await eventually { await h.engine.parkedCount > 0 })
    let gateway = "aa:bb:cc:00:11:22"
    h.detector.set(primary: wifi(nil, gateway: gateway), active: [wifi(nil, gateway: gateway)])
    await h.step(seconds: 5)
    #expect(await h.engine.parkedCount == 0)
    await h.engine.flush()
    let networks = try await h.store.networks()
    #expect(networks.map(\.key.fingerprint) == ["wifi:gw:\(gateway)"])
    let usage = try await h.store.appUsage(network: networks.first?.id, in: DateInterval(start: .distantPast, end: .distantFuture))
    #expect(usage.first { $0.id == "proc:curl" }?.down == 5000)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func periodicFlushRunsWhileReadsFail() async throws {
    let h = try Harness()
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 2_000)
    await h.step()
    h.reader.setFailing(true)
    for _ in 0..<28 { await h.step() }
    #expect(await h.engine.latestSnapshot.state == .degraded("Interface counters unavailable"))
    #expect(try await h.totals() == Totals(down: 2_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func switchToAnotherNetworkSettlesHeldBytesToUnknownWiFi() async throws {
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)))
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 3_000)
    await h.step()
    #expect(await h.engine.parkedCount == 1)
    h.detector.set(primary: wifi("Office"), active: [wifi("Office")])
    await h.engine.networkChanged()
    #expect(await h.engine.parkedCount == 0)
    h.reader.add("en0", kind: .wifi, rx: 2_000)
    await h.step()
    await h.engine.flush()
    #expect(try await h.totals(network: UsageAccumulator.unknownWiFi.fingerprint) == Totals(down: 3_000, up: 0))
    #expect(try await h.totals(network: "wifi:ssid:Office") == Totals(down: 2_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func heldWiFiAppSamplesDoNotLandOnNewlyResolvedEthernet() async throws {
    let launcher = FakeLauncher { _, _ in ([header, "x.9,1,1,", header, "curl.42,5000,100,", header], false) }
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)), launcher: launcher)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    #expect(await eventually { await h.engine.parkedCount > 0 })
    let eth = ethernet(mac: "00:11:22:33:44:55")
    h.detector.set(primary: eth, active: [eth, wifi(nil)])
    await h.engine.networkChanged()
    await h.engine.flush()
    let all = DateInterval(start: .distantPast, end: .distantFuture)
    let networks = try await h.store.networks()
    let ethID = try #require(networks.first { $0.key.fingerprint == "eth:00:11:22:33:44:55" }?.id)
    let unknownID = try #require(networks.first { $0.key == UsageAccumulator.unknownWiFi }?.id)
    #expect(try await h.store.appUsage(network: ethID, in: all).allSatisfy { $0.id != "proc:curl" })
    #expect(try await h.store.appUsage(network: unknownID, in: all).first { $0.id == "proc:curl" }?.down == 5000)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func parkedTrafficSettlesAfterSixtySecondsDespiteChangeEvents() async throws {
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)))
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    for second in 2...61 {
        h.reader.add("en0", kind: .wifi, rx: 1_000)
        await h.step()
        if second % 20 == 0 { await h.engine.networkChanged() }
    }
    #expect(await h.engine.parkedCount == 60)
    h.reader.add("en0", kind: .wifi, rx: 1_000)
    await h.step()
    #expect(await h.engine.parkedCount == 1)
    await h.engine.flush()
    #expect(try await h.totals(network: UsageAccumulator.unknownWiFi.fingerprint) == Totals(down: 61_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func heldTrafficFromBeforeAnIdenticalLookingSwitchIsNotRekeyed() async throws {
    let launcher = FakeLauncher { index, _ in index == 0 ? ([header, "x.9,1,1,", header, "curl.42,5000,100,", header], false) : ([], false) }
    let h = try Harness(detector: FakeDetector(primary: wifi(nil)), launcher: launcher)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 3_000)
    await h.step()
    #expect(await eventually { await h.engine.parkedCount == 2 })
    await h.engine.networkChanged()
    #expect(await h.engine.parkedCount == 2)
    h.reader.add("en0", kind: .wifi, rx: 2_000)
    await h.step()
    let gateway = "aa:bb:cc:00:11:22"
    h.detector.set(primary: wifi(nil, gateway: gateway), active: [wifi(nil, gateway: gateway)])
    h.reader.add("en0", kind: .wifi, rx: 7_000)
    await h.step(seconds: 5)
    #expect(await h.engine.parkedCount == 0)
    await h.engine.flush()
    #expect(try await h.totals(network: UsageAccumulator.unknownWiFi.fingerprint) == Totals(down: 3_000, up: 0))
    #expect(try await h.totals(network: "wifi:gw:\(gateway)") == Totals(down: 9_000, up: 0))
    let all = DateInterval(start: .distantPast, end: .distantFuture)
    let networks = try await h.store.networks()
    let gwID = try #require(networks.first { $0.key.fingerprint == "wifi:gw:\(gateway)" }?.id)
    let unknownID = try #require(networks.first { $0.key == UsageAccumulator.unknownWiFi }?.id)
    #expect(try await h.store.appUsage(network: gwID, in: all).allSatisfy { $0.id != "proc:curl" })
    #expect(try await h.store.appUsage(network: unknownID, in: all).first { $0.id == "proc:curl" }?.down == 5000)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func refreshNetworkIdentityRekeysToSSIDWithoutChangeEvent() async throws {
    let detector = FakeDetector(primary: wifi(nil, gateway: "aa:bb:cc:00:11:22"))
    let h = try Harness(detector: detector)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    #expect(await eventually { await h.engine.latestSnapshot.primaryNetwork?.key.fingerprint == "wifi:gw:aa:bb:cc:00:11:22" })
    detector.set(primary: wifi("Home"), active: [wifi("Home")])
    await h.engine.refreshNetworkIdentity()
    #expect(await eventually { await h.engine.latestSnapshot.primaryNetwork?.key.fingerprint == "wifi:ssid:Home" })
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func gatewayRowMergesIntoSSIDRowWhenSSIDResolves() async throws {
    let gateway = "aa:bb:cc:00:11:22"
    let detector = FakeDetector(primary: wifi(nil, gateway: gateway))
    let h = try Harness(detector: detector)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 4_000)
    await h.step()
    await h.engine.flush()
    #expect(try await h.store.networks().map(\.key.fingerprint) == ["wifi:gw:\(gateway)"])
    h.reader.add("en0", kind: .wifi, rx: 1_000)
    await h.step()
    detector.set(primary: wifi("Home", gateway: gateway), active: [wifi("Home", gateway: gateway)])
    await h.engine.refreshNetworkIdentity()
    h.reader.add("en0", kind: .wifi, rx: 2_000)
    await h.step()
    await h.engine.flush()
    #expect(try await h.store.networks().map(\.key.fingerprint) == ["wifi:ssid:Home"])
    #expect(try await h.totals(network: "wifi:ssid:Home") == Totals(down: 7_000, up: 0))
    #expect(await h.engine.latestSnapshot.primaryNetwork?.key.fingerprint == "wifi:ssid:Home")
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func pendingIdentityParksGatewayOnlyWiFiUntilSSIDArrives() async throws {
    let gateway = "aa:bb:cc:00:11:22"
    let detector = FakeDetector(primary: wifi(nil, gateway: gateway))
    let h = try Harness(detector: detector)
    await h.engine.setIdentityPending(true)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    for _ in 0..<10 {
        h.reader.add("en0", kind: .wifi, rx: 1_000)
        await h.step()
    }
    #expect(await h.engine.parkedCount > 0)
    #expect(await h.engine.latestSnapshot.primaryNetwork == nil)
    #expect(try await h.store.networks().isEmpty)
    detector.set(primary: wifi("Home", gateway: gateway), active: [wifi("Home", gateway: gateway)])
    await h.engine.setIdentityPending(false)
    await h.engine.refreshNetworkIdentity()
    await h.engine.flush()
    #expect(try await h.store.networks().map(\.key.fingerprint) == ["wifi:ssid:Home"])
    #expect(try await h.totals(network: "wifi:ssid:Home") == Totals(down: 10_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func pendingIdentityFallsBackToGatewayRowAfterAMinute() async throws {
    let gateway = "aa:bb:cc:00:11:22"
    let h = try Harness(detector: FakeDetector(primary: wifi(nil, gateway: gateway)))
    await h.engine.setIdentityPending(true)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    for _ in 0..<60 {
        h.reader.add("en0", kind: .wifi, rx: 1_000)
        await h.step()
    }
    await h.engine.flush()
    #expect(await h.engine.parkedCount == 0)
    #expect(await h.engine.latestSnapshot.primaryNetwork?.key.fingerprint == "wifi:gw:\(gateway)")
    #expect(try await h.totals(network: "wifi:gw:\(gateway)") == Totals(down: 60_000, up: 0))
    #expect(try await h.totals(network: UsageAccumulator.unknownWiFi.fingerprint) == Totals(down: 0, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func identityDecidedWithoutSSIDUsesGatewayRowRightAway() async throws {
    let gateway = "aa:bb:cc:00:11:22"
    let h = try Harness(detector: FakeDetector(primary: wifi(nil, gateway: gateway)))
    await h.engine.setIdentityPending(true)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    h.reader.add("en0", kind: .wifi, rx: 3_000)
    await h.step()
    await h.engine.setIdentityPending(false)
    #expect(await eventually { await h.engine.latestSnapshot.primaryNetwork?.key.fingerprint == "wifi:gw:\(gateway)" })
    await h.engine.flush()
    #expect(try await h.totals(network: "wifi:gw:\(gateway)") == Totals(down: 3_000, up: 0))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func startAfterStaleHeartbeatRecordsNotRunningGap() async throws {
    let h = try Harness()
    try await h.store.setHeartbeat(baseDate.addingTimeInterval(-3600))
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    await h.engine.flush()
    let gaps = try await h.store.gaps()
    #expect(gaps.count == 1)
    #expect(gaps.first?.reason == "not running")
    #expect(gaps.first?.start == baseDate.addingTimeInterval(-3600))
    #expect(try await h.hasGapToday())
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func startAfterRecentHeartbeatRecordsNoGap() async throws {
    let h = try Harness()
    try await h.store.setHeartbeat(baseDate.addingTimeInterval(-30))
    await h.engine.start()
    await h.engine.flush()
    #expect(try await h.store.gaps().isEmpty)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func flushWritesHeartbeat() async throws {
    let h = try Harness()
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    await h.step()
    await h.step(seconds: 30)
    #expect(try await eventually { try await h.store.heartbeat() == baseDate.addingTimeInterval(31) })
    h.clock.advance(.seconds(10))
    await h.engine.pause()
    h.clock.advance(.seconds(100))
    await h.engine.flush()
    #expect(try await h.store.heartbeat() == baseDate.addingTimeInterval(41))
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func lightSecondInterfaceTrafficDoesNotSplit() async throws {
    let detector = FakeDetector(primary: wifi("Home"), active: [wifi("Home"), ethernet(mac: "00:11:22:33:44:55")])
    let h = try Harness(detector: detector)
    h.reader.add("en0", kind: .wifi)
    h.reader.add("en5", kind: .ethernet)
    await h.engine.start()
    await h.step()
    for _ in 0..<10 {
        h.reader.add("en0", kind: .wifi, rx: 500_000)
        h.reader.add("en5", kind: .ethernet, rx: 9_000)
        await h.step()
    }
    #expect(await !h.engine.isSplit)
    await h.engine.setFastSampling(false)
    for _ in 0..<5 {
        h.reader.add("en0", kind: .wifi, rx: 500_000)
        h.reader.add("en5", kind: .ethernet, rx: 20_000)
        await h.step(seconds: 5)
    }
    #expect(await !h.engine.isSplit)
    await h.finish()
}

@Test(.timeLimit(.minutes(1))) func unchangedSnapshotsAreNotRepublished() async throws {
    let h = try Harness()
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    // start() looks up the stored network in a background task that publishes once it is found. Settle that lookup
    // first so the baseline isn't taken before it lands; a repeat of it then publishes nothing new.
    await h.engine.refreshNetworkIdentity()
    await h.step()
    await h.engine.flush()
    let before = await h.engine.publishCount
    for _ in 0..<5 { await h.step() }
    #expect(await h.engine.publishCount == before)
    h.reader.add("en0", kind: .wifi, rx: 3_000)
    await h.step()
    #expect(await h.engine.publishCount == before + 1)
    await h.finish()
}

private struct BinProcessInfo: ProcessInfoProviding {
    func executablePath(pid: Int32) -> String? { "/usr/bin/tool\(pid)" }
    func responsiblePID(pid: Int32) -> Int32? { nil }
    func bundleInfo(atPath: String) -> (id: String, name: String)? { nil }
}

@Test(.timeLimit(.minutes(1))) func resolverCacheKeepsOnlyProcessesInTheLatestBlock() async throws {
    let launcher = FakeLauncher { _, _ in ([header, "x.9,1,1,", header, "curl.42,5000,100,", header, "wget.43,10,10,", header], false) }
    let resolver = AppResolver(provider: BinProcessInfo())
    let h = try Harness(launcher: launcher, resolver: resolver)
    h.reader.add("en0", kind: .wifi)
    await h.engine.start()
    #expect(try await eventually {
        await h.engine.flush()
        let usage = try await h.store.appUsage(network: nil, in: DateInterval(start: .distantPast, end: .distantFuture))
        return usage.contains { $0.id == "proc:tool43" }
    })
    #expect(resolver.cachedCount == 1)
    await h.finish()
}
