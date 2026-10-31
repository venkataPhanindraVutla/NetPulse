import Foundation
import os

public enum MonitorState: Sendable, Equatable {
    case monitoring, paused, degraded(String)
}

public struct EngineSnapshot: Sendable, Equatable {
    public let speed: Speed
    public let primaryNetwork: StoredNetwork?
    public let state: MonitorState
    public let appTrackingAvailable: Bool

    public init(speed: Speed, primaryNetwork: StoredNetwork?, state: MonitorState, appTrackingAvailable: Bool) {
        self.speed = speed
        self.primaryNetwork = primaryNetwork
        self.state = state
        self.appTrackingAvailable = appTrackingAvailable
    }
}

struct EngineClock: Sendable {
    var now: @Sendable () -> Date
    var instant: @Sendable () -> ContinuousClock.Instant
    var sleep: @Sendable (Duration) async -> Void

    static let live = EngineClock(
        now: { Date() },
        instant: { ContinuousClock.now },
        sleep: { try? await Task.sleep(for: $0, tolerance: $0 / 10) }
    )
}

public actor MonitorEngine {
    static let flushInterval: Duration = .seconds(30)
    static let splitAfterTicks = 3
    static let splitMinimumRate: Double = 10_000
    static let mergeAfter: Duration = .seconds(60)
    static let networkRetryInterval: Duration = .seconds(5)
    static let networkRetryWindow: Duration = .seconds(60)
    static let staleHeartbeat: TimeInterval = 60

    private struct NettopStream {
        let id: Int
        let filter: NettopFilter
        let supervisor: NettopSupervisor
        let task: Task<Void, Never>
        var lastDataAt: Date
        var inBackoff = false
        var pendingGap: String?
        var pids: Set<Int32> = []
    }

    private enum Route {
        case network(NetworkKey)
        case park(fallback: NetworkKey?)
        case drop
    }

    private struct ParkedItem {
        enum Payload {
            case interface(InterfaceDelta)
            case apps([(ProcessSample, AppIdentity)], filter: NettopFilter)
        }

        let payload: Payload
        let at: Date
        let fallback: NetworkKey?
        let primaryAtPark: NetworkObservation?
        let generation: Int
    }

    private let store: UsageStore
    private let reader: any InterfaceCounterReading
    private let detector: any NetworkDetecting
    private let resolver: AppResolver
    private let launcher: any LineProcessLaunching
    private let nettopInterval: Int
    private let clock: EngineClock
    private let log = Logger(subsystem: "NetPulse", category: "engine")

    private var tracker = DeltaTracker()
    private var speedCalculator = SpeedCalculator()
    private var accumulator = UsageAccumulator()
    private var unwritten: [UsageRow] = []
    private var deltaRx: UInt64 = 0
    private var deltaTx: UInt64 = 0
    private var speed = Speed.zero

    private var started = false
    private var paused = false
    private var asleep = false
    private var pausedAt: Date?
    private var sleptAt: Date?
    private var degradedReason: String?
    private var fast = true

    private var tickTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var storeChain: Task<Void, Never>?
    private var streams: [NettopStream] = []
    private var nextStreamID = 0
    private(set) var isSplit = false
    private(set) var publishCount = 0
    private var multiActiveTicks = 0
    private var lastMultiActiveAt: ContinuousClock.Instant?
    private var lastFlushAt: ContinuousClock.Instant
    private var lastIngestAt: ContinuousClock.Instant?

    private var primaryObservation: NetworkObservation?
    private var primaryKey: NetworkKey?
    private var interfaceKeys: [String: NetworkKey] = [:]
    private var wifiKey: NetworkKey?
    private var wifiInterface: String?
    private var wiredKey: NetworkKey?
    private var primaryStored: StoredNetwork?
    private var lastNetworkRefreshAt: ContinuousClock.Instant?
    private var unresolvedSince: ContinuousClock.Instant?
    private var fallbackApplied = false
    private var parked: [ParkedItem] = []
    private var parkedSince: ContinuousClock.Instant?
    private var changeGeneration = 0
    private var identityPending = false
    private var deferredKeys: [String: NetworkKey] = [:]
    private var pendingMerges: [(from: NetworkKey, into: NetworkKey)] = []
    var parkedCount: Int { parked.count }

    private var subscribers: [UUID: AsyncStream<EngineSnapshot>.Continuation] = [:]
    private(set) var latestSnapshot = EngineSnapshot(speed: .zero, primaryNetwork: nil, state: .monitoring, appTrackingAvailable: true)

    public init(
        store: UsageStore,
        reader: any InterfaceCounterReading,
        detector: any NetworkDetecting,
        resolver: AppResolver,
        launcher: any LineProcessLaunching,
        nettopInterval: Int = 5
    ) {
        self.init(store: store, reader: reader, detector: detector, resolver: resolver, launcher: launcher, nettopInterval: nettopInterval, clock: .live)
    }

    init(
        store: UsageStore,
        reader: any InterfaceCounterReading,
        detector: any NetworkDetecting,
        resolver: AppResolver,
        launcher: any LineProcessLaunching,
        nettopInterval: Int,
        clock: EngineClock
    ) {
        self.store = store
        self.reader = reader
        self.detector = detector
        self.resolver = resolver
        self.launcher = launcher
        self.nettopInterval = nettopInterval
        self.clock = clock
        lastFlushAt = clock.instant()
    }

    deinit {
        tickTask?.cancel()
        changesTask?.cancel()
        for stream in streams { stream.task.cancel() }
    }

    public func start() {
        guard !started else { return }
        started = true
        recordTimeNotRunning()
        refreshNetworks()
        let changes = detector.changes()
        changesTask = Task { [weak self] in
            for await _ in changes { await self?.networkChanged() }
        }
        beginMonitoring()
        publish()
        Task { await self.networkChanged(refresh: false) }
    }

    public func pause() {
        guard started, !paused else { return }
        paused = true
        pausedAt = clock.now()
        if !asleep { endMonitoring() }
        publish()
    }

    public func resume() {
        guard started, paused else { return }
        paused = false
        if let pausedAt { recordGap(start: pausedAt, end: clock.now(), reason: "paused") }
        pausedAt = nil
        if !asleep {
            refreshNetworks()
            beginMonitoring()
        }
        publish()
    }

    public func willSleep() {
        guard started, !asleep else { return }
        asleep = true
        guard !paused else { return }
        sleptAt = clock.now()
        endMonitoring()
    }

    public func didWake() {
        guard started, asleep else { return }
        asleep = false
        if let sleptAt { recordGap(start: sleptAt, end: clock.now(), reason: "sleep") }
        sleptAt = nil
        refreshNetworks()
        if !paused { beginMonitoring() }
        publish()
        Task { await self.networkChanged(refresh: false) }
    }

    public func flush() async {
        commitParked()
        await writeAccumulated()
    }

    private func writeAccumulated() async {
        scheduleFlush()
        await storeChain?.value
        await updatePrimaryStored()
    }

    public func snapshots() -> AsyncStream<EngineSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(currentSnapshot)
        return stream
    }

    public func setFastSampling(_ fast: Bool) {
        guard fast != self.fast else { return }
        self.fast = fast
        if isRunning { startTicking() }
    }

    private var isRunning: Bool { started && !paused && !asleep }

    private func beginMonitoring() {
        tracker.reset()
        speedCalculator.reset()
        speed = .zero
        multiActiveTicks = 0
        lastMultiActiveAt = nil
        lastIngestAt = nil
        isSplit = false
        lastFlushAt = clock.instant()
        startStreams([.physical], pendingGap: nil)
        startTicking()
    }

    private func endMonitoring() {
        tickTask?.cancel()
        tickTask = nil
        stopStreams()
        speed = .zero
        commitParked()
        scheduleFlush()
    }

    private func startTicking() {
        tickTask?.cancel()
        let sleep = clock.sleep
        let interval: Duration = fast ? .seconds(1) : .seconds(5)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(interval)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    func tick() async {
        guard isRunning else { return }
        await maintainNetworkResolution()
        guard isRunning else { return }
        let instant = clock.instant()
        do {
            let counters = try reader.read()
            degradedReason = nil
            ingest(counters, now: clock.now(), at: instant)
        } catch {
            log.error("interface read failed: \(String(describing: error), privacy: .public)")
            degradedReason = "Interface counters unavailable"
            speed = .zero
        }
        if lastFlushAt.duration(to: instant) >= Self.flushInterval {
            lastFlushAt = instant
            await writeAccumulated()
        }
        publish()
    }

    private func ingest(_ counters: [InterfaceCounter], now: Date, at instant: ContinuousClock.Instant) {
        let (deltas, discontinuities) = tracker.ingest(counters)
        for d in discontinuities {
            log.info("interface discontinuity: \(String(describing: d), privacy: .public)")
        }
        for d in deltas {
            deltaRx &+= d.rx
            deltaTx &+= d.tx
        }
        speed = speedCalculator.update(totalRx: deltaRx, totalTx: deltaTx, at: instant)
        let elapsed = lastIngestAt.map { Self.seconds($0.duration(to: instant)) } ?? 0
        lastIngestAt = instant

        for d in deltas where d.rx != 0 || d.tx != 0 {
            switch route(interface: d.name, kind: d.kind) {
            case .network(let key): accumulator.addInterface([d], networkFor: { _ in key }, at: now)
            case .park(let fallback): park(.interface(d), at: now, fallback: fallback)
            case .drop: break
            }
        }

        // Splitting costs a second nettop; only sustained traffic on both uplinks is worth it.
        let busy = elapsed > 0 ? deltas.filter { $0.kind.isPhysical && Double($0.rx &+ $0.tx) / elapsed >= Self.splitMinimumRate }.count : 0
        updateSplit(activeCount: busy, at: instant, now: now)
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func updateSplit(activeCount: Int, at instant: ContinuousClock.Instant, now: Date) {
        if activeCount >= 2 {
            multiActiveTicks += 1
            lastMultiActiveAt = instant
        } else {
            multiActiveTicks = 0
        }
        if !isSplit, multiActiveTicks >= Self.splitAfterTicks {
            swapStreams(split: true, now: now)
        } else if isSplit, let last = lastMultiActiveAt, last.duration(to: instant) >= Self.mergeAfter {
            swapStreams(split: false, now: now)
        }
    }

    private func swapStreams(split: Bool, now: Date) {
        let since = streams.map(\.lastDataAt).min() ?? now
        stopStreams()
        isSplit = split
        let reason = split ? "nettop split" : "nettop merge"
        log.info("\(reason, privacy: .public)")
        recordGap(start: since, end: now, reason: reason)
        startStreams(split ? [.wifi, .wired] : [.physical], pendingGap: reason)
    }

    private func startStreams(_ filters: [NettopFilter], pendingGap: String?) {
        let now = clock.now()
        for filter in filters {
            let supervisor = NettopSupervisor(filter: filter, interval: nettopInterval, launcher: launcher)
            let id = nextStreamID
            nextStreamID += 1
            let task = Task { [weak self] in
                let events = await supervisor.blocks()
                for await event in events {
                    guard let self else { return }
                    await self.handle(event, stream: id)
                }
            }
            streams.append(NettopStream(id: id, filter: filter, supervisor: supervisor, task: task, lastDataAt: now, pendingGap: pendingGap))
        }
    }

    private func stopStreams() {
        let now = clock.now()
        for stream in streams {
            stream.task.cancel()
            let supervisor = stream.supervisor
            Task { await supervisor.stop() }
            if let reason = stream.pendingGap { recordGap(start: stream.lastDataAt, end: now, reason: reason) }
        }
        streams = []
    }

    private func handle(_ event: NettopEvent, stream id: Int) {
        guard let index = streams.firstIndex(where: { $0.id == id }) else { return }
        let wasAvailable = appTrackingAvailable
        let now = clock.now()
        switch event {
        case .gap(let reason):
            let label = "nettop \(reason)"
            let filter = streams[index].filter.rawValue
            log.notice("\(label, privacy: .public) (\(filter, privacy: .public))")
            recordGap(start: streams[index].lastDataAt, end: now, reason: label)
            streams[index].lastDataAt = now
            streams[index].inBackoff = true
            streams[index].pendingGap = label
        case .samples(let samples):
            if let reason = streams[index].pendingGap {
                recordGap(start: streams[index].lastDataAt, end: now, reason: reason)
                streams[index].pendingGap = nil
            }
            streams[index].inBackoff = false
            streams[index].lastDataAt = now
            streams[index].pids = Set(samples.map(\.pid))
            resolver.retainOnly(pids: streams.reduce(into: Set<Int32>()) { $0.formUnion($1.pids) })
            attribute(samples, filter: streams[index].filter, at: now)
        }
        if appTrackingAvailable != wasAvailable { publish() }
    }

    private func attribute(_ samples: [ProcessSample], filter: NettopFilter, at now: Date) {
        let nonzero = samples.filter { $0.bytesIn != 0 || $0.bytesOut != 0 }
        guard !nonzero.isEmpty else { return }
        let resolved = nonzero.map { ($0, resolver.resolve($0)) }
        switch route(filter: filter) {
        case .network(let key): accumulator.addApps(resolved, network: key, at: now)
        case .park(let fallback): park(.apps(resolved, filter: filter), at: now, fallback: fallback)
        case .drop: log.debug("no network for \(filter.rawValue, privacy: .public) app samples; left to Other")
        }
    }

    private var appTrackingAvailable: Bool { !streams.contains(where: \.inBackoff) }

    /// While Location permission is undecided an SSID may still appear, so Wi-Fi known only by its router is held
    /// like an unresolved network (bounded by the retry window) instead of creating a router-keyed row at once.
    public func setIdentityPending(_ pending: Bool) async {
        guard pending != identityPending else { return }
        identityPending = pending
        guard started, !pending else { return }
        await networkChanged()
    }

    public func refreshNetworkIdentity() async {
        guard started else { return }
        await networkChanged()
    }

    func networkChanged(refresh: Bool = true) async {
        if refresh { refreshNetworks() }
        await updatePrimaryStored()
        publish()
    }

    // Right after a join the gateway may not be in the ARP table yet, so an unresolved primary is retried for a minute.
    // Meanwhile its traffic is parked; it moves to the resolved network, or to the fallback once the minute is up.
    private var isRetryingNetwork: Bool { unresolvedSince != nil && !fallbackApplied }

    private func maintainNetworkResolution() async {
        let instant = clock.instant()
        if let since = unresolvedSince, !fallbackApplied {
            if since.duration(to: instant) >= Self.networkRetryWindow {
                log.notice("network still unresolved after a minute; using fallback")
                fallbackApplied = true
                commitParked()
                await updatePrimaryStored()
            } else if let last = lastNetworkRefreshAt, last.duration(to: instant) >= Self.networkRetryInterval {
                refreshNetworks(retry: true)
                await updatePrimaryStored()
            }
        }
        if let parkedSince, parkedSince.duration(to: clock.instant()) >= Self.networkRetryWindow { commitParked() }
    }

    private func refreshNetworks(retry: Bool = false) {
        let primary = detector.primary()
        let active = detector.activePhysical()
        // After a change event the held bytes may belong to the network we just left. Two unresolved observations can look
        // identical, so only items from the current generation can later move to the resolved network.
        if !retry {
            changeGeneration += 1
            commitParked { $0.primaryAtPark != primary }
        }
        var keys: [String: NetworkKey] = [:]
        var deferred: [String: NetworkKey] = [:]
        let observations = active.filter { $0.interfaceName != primary?.interfaceName } + (primary.map { [$0] } ?? [])
        for observation in observations {
            if let key = identityKey(for: observation) {
                keys[observation.interfaceName] = key
                if key.fingerprint.hasPrefix("wifi:ssid:"), let gateway = NetworkIdentity.gatewayKey(for: observation),
                   !pendingMerges.contains(where: { $0.from == gateway }) {
                    pendingMerges.append((gateway, key))
                }
            } else if let gateway = NetworkIdentity.gatewayKey(for: observation) {
                deferred[observation.interfaceName] = gateway
            } else if observation.kind != .wifi {
                log.notice("no network identity for \(observation.interfaceName, privacy: .public); its bytes count toward speed only")
            }
        }
        primaryObservation = primary
        primaryKey = primary.flatMap(identityKey(for:))
        interfaceKeys = keys
        deferredKeys = deferred
        wifiInterface = active.first { $0.kind == .wifi }?.interfaceName
        wifiKey = active.first { $0.kind == .wifi }.flatMap(identityKey(for:))
        wiredKey = active.first { $0.kind == .ethernet }.flatMap(identityKey(for:))

        let instant = clock.instant()
        lastNetworkRefreshAt = instant
        if primaryKey != nil {
            unresolvedSince = nil
            fallbackApplied = false
        } else if !retry || unresolvedSince == nil {
            unresolvedSince = instant
            fallbackApplied = false
        }
        if !isRetryingNetwork { settleParked(resolvedPrimary: primary) }
    }

    private func identityKey(for observation: NetworkObservation) -> NetworkKey? {
        guard let key = NetworkIdentity.key(for: observation) else { return nil }
        if identityPending, key.fingerprint.hasPrefix("wifi:gw:") { return nil }
        return key
    }

    /// Where unkeyed Wi-Fi bytes go once the network stops being retried.
    private func wifiFallback(_ interface: String?) -> NetworkKey {
        interface.flatMap { deferredKeys[$0] } ?? UsageAccumulator.unknownWiFi
    }

    private var displayKey: NetworkKey? {
        if let primaryKey { return primaryKey }
        if let primary = primaryObservation, primary.kind == .wifi, !isRetryingNetwork { return wifiFallback(primary.interfaceName) }
        return nil
    }

    private func route(interface name: String, kind: InterfaceKind) -> Route {
        if let key = interfaceKeys[name] { return .network(key) }
        guard kind == .wifi else { return .drop }
        let fallback = wifiFallback(name)
        return isRetryingNetwork ? .park(fallback: fallback) : .network(fallback)
    }

    private func route(filter: NettopFilter) -> Route {
        switch filter {
        case .physical:
            if let primaryKey { return .network(primaryKey) }
            let fallback = primaryObservation.flatMap { $0.kind == .wifi ? wifiFallback($0.interfaceName) : nil }
            if isRetryingNetwork { return .park(fallback: fallback) }
            return fallback.map(Route.network) ?? .drop
        case .wifi:
            if let wifiKey { return .network(wifiKey) }
            let fallback = wifiFallback(wifiInterface)
            return isRetryingNetwork ? .park(fallback: fallback) : .network(fallback)
        case .wired:
            return wiredKey.map(Route.network) ?? .drop
        }
    }

    private func park(_ payload: ParkedItem.Payload, at: Date, fallback: NetworkKey?) {
        parked.append(ParkedItem(payload: payload, at: at, fallback: fallback, primaryAtPark: primaryObservation, generation: changeGeneration))
        if parkedSince == nil { parkedSince = clock.instant() }
    }

    /// The primary resolved: items parked on the same interface since the last change event move to its network;
    /// the rest go to their park-time fallback.
    private func settleParked(resolvedPrimary primary: NetworkObservation?) {
        let items = takeParked { _ in true }
        for item in items {
            let sameNetwork = primary != nil
                && item.generation == changeGeneration
                && item.primaryAtPark?.interfaceName == primary?.interfaceName
                && item.primaryAtPark?.kind == primary?.kind
            var key = item.fallback
            if sameNetwork, case .network(let resolved) = route(for: item.payload) { key = resolved }
            add(item, to: key)
        }
    }

    /// Commits parked items to the fallback recorded when they were parked.
    private func commitParked(where shouldCommit: (ParkedItem) -> Bool = { _ in true }) {
        for item in takeParked(where: shouldCommit) { add(item, to: item.fallback) }
    }

    private func takeParked(where shouldTake: (ParkedItem) -> Bool) -> [ParkedItem] {
        let taken = parked.filter(shouldTake)
        guard !taken.isEmpty else { return [] }
        parked.removeAll(where: shouldTake)
        if parked.isEmpty { parkedSince = nil }
        return taken
    }

    private func route(for payload: ParkedItem.Payload) -> Route {
        switch payload {
        case .interface(let d): route(interface: d.name, kind: d.kind)
        case .apps(_, let filter): route(filter: filter)
        }
    }

    private func add(_ item: ParkedItem, to key: NetworkKey?) {
        guard let key else { return }
        switch item.payload {
        case .interface(let d): accumulator.addInterface([d], networkFor: { _ in key }, at: item.at)
        case .apps(let samples, _): accumulator.addApps(samples, network: key, at: item.at)
        }
    }

    private func updatePrimaryStored() async {
        await mergeResolvedGatewayRows()
        guard let key = displayKey else {
            primaryStored = nil
            return
        }
        do {
            var found = try await store.networks().first { $0.key.fingerprint == key.fingerprint }
            if found == nil {
                let row = UsageRow(bucketStart: PeriodBoundaries.bucketStart(clock.now()), network: key, app: nil, down: 0, up: 0)
                try await store.write([row])
                found = try await store.networks().first { $0.key.fingerprint == key.fingerprint }
            }
            if displayKey == key { primaryStored = found }
        } catch {
            log.error("network lookup failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A Wi-Fi first seen by its router (SSID unreadable) and later by its SSID would otherwise keep two rows.
    /// Held bytes are written first so the merge, queued behind them, sees every router-keyed row.
    private func mergeResolvedGatewayRows() async {
        guard !pendingMerges.isEmpty else { return }
        let merges = pendingMerges
        pendingMerges = []
        scheduleFlush()
        let log = log
        for merge in merges {
            enqueue { store in
                do {
                    try await store.mergeNetwork(from: merge.from, into: merge.into)
                } catch {
                    log.error("network merge failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        await storeChain?.value
    }

    private func scheduleFlush() {
        let rows = unwritten + accumulator.drain()
        unwritten = []
        let heartbeat = started ? monitoredUntil : nil
        let log = log
        guard !rows.isEmpty || heartbeat != nil else { return }
        enqueue { [weak self] store in
            if !rows.isEmpty {
                do {
                    try await store.write(rows)
                } catch {
                    await self?.requeue(rows, error: error)
                }
            }
            guard let heartbeat else { return }
            do {
                try await store.setHeartbeat(heartbeat)
            } catch {
                log.error("heartbeat write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The last moment traffic was being counted: now while running, else when the pause or sleep began.
    private var monitoredUntil: Date {
        isRunning ? clock.now() : (pausedAt ?? sleptAt ?? clock.now())
    }

    private func recordTimeNotRunning() {
        let now = clock.now()
        let log = log
        enqueue { store in
            do {
                guard let last = try await store.heartbeat(), now.timeIntervalSince(last) > Self.staleHeartbeat else { return }
                try await store.recordGap(start: last, end: now, reason: "not running")
            } catch {
                log.error("heartbeat check failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func requeue(_ rows: [UsageRow], error: any Error) {
        log.error("flush failed, will retry: \(String(describing: error), privacy: .public)")
        unwritten = rows + unwritten
    }

    private func recordGap(start: Date, end: Date, reason: String) {
        guard end >= start else { return }
        let log = log
        enqueue { store in
            do {
                try await store.recordGap(start: start, end: end, reason: reason)
            } catch {
                log.error("gap write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func enqueue(_ work: @escaping @Sendable (UsageStore) async -> Void) {
        let previous = storeChain
        let store = store
        storeChain = Task {
            await previous?.value
            await work(store)
        }
    }

    private var state: MonitorState {
        if paused { return .paused }
        if let degradedReason { return .degraded(degradedReason) }
        return .monitoring
    }

    private var currentSnapshot: EngineSnapshot {
        EngineSnapshot(
            speed: isRunning ? speed : .zero,
            primaryNetwork: primaryStored,
            state: state,
            appTrackingAvailable: appTrackingAvailable
        )
    }

    private func publish() {
        let snapshot = currentSnapshot
        guard snapshot != latestSnapshot else { return }
        latestSnapshot = snapshot
        publishCount += 1
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }
}
