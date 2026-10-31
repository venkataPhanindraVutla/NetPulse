import AppKit
import NetPulseCore
import Observation
import os
import UserNotifications

enum SettingsTab: Hashable {
    case general, networks
}

enum PopoverTab: String, CaseIterable {
    case now, apps, history

    var title: String {
        switch self {
        case .now: "Now"
        case .apps: "Apps"
        case .history: "History"
        }
    }
}

enum LabelStyle: String, CaseIterable, Codable {
    case stacked, singleLine, downloadOnly, iconOnly
}

/// What the menu bar shows. It changes only when a displayed string changes, so the label is not rebuilt every tick.
struct MenuBarText: Equatable {
    var up = ""
    var down = ""
    var paused = false
}

@MainActor @Observable
final class AppModel {
    static let labelStyleKey = "labelStyle"
    static let rateUnitKey = "rateUnit"
    static let loginOfferedKey = "didOfferLoginItem"
    static let handledNamesKey = "handledNameNetworkIDs"
    static let pausedKey = "isPaused"

    var snapshot: EngineSnapshot? {
        didSet { updateMenuBarText() }
    }
    private(set) var menuBarText = MenuBarText()
    var labelStyle: LabelStyle {
        didSet {
            defaults.set(labelStyle.rawValue, forKey: Self.labelStyleKey)
            if labelStyle != oldValue { updateSampling() }
            updateMenuBarText()
        }
    }
    var rateUnit: RateUnit {
        didSet {
            defaults.set(rateUnit == .bitsPerSecond ? "bits" : "bytes", forKey: Self.rateUnitKey)
            updateMenuBarText()
        }
    }
    var settingsTab: SettingsTab = .general
    var notificationStatus: NotificationAuthorization = .unknown
    var loginOffered: Bool
    var handledNameNetworks: Set<Int64>
    var popoverOpen = false {
        didSet { if popoverOpen != oldValue { updateSampling() } }
    }

    var tab: PopoverTab = .now
    var appsPeriod: Period = .day {
        didSet { if appsPeriod != oldValue { scheduleRefresh() } }
    }
    var appsNetwork: Int64? {
        didSet { if appsNetwork != oldValue { scheduleRefresh() } }
    }
    /// Year and month, not an instant, so the selection means the same month after a time zone change.
    var historyMonth: DateComponents = AppModel.month(of: Date()) {
        didSet { if historyMonth != oldValue { scheduleRefresh() } }
    }
    var historyMonthStart: Date { Calendar.current.date(from: historyMonth) ?? Date() }
    var historyNetwork: Int64? {
        didSet { if historyNetwork != oldValue { scheduleRefresh() } }
    }

    var networks: [StoredNetwork] = []
    var today = Totals(down: 0, up: 0)
    var topApps: [AppUsage] = []
    var apps: [AppUsage] = []
    var days: [DayUsage] = []
    var periodTotals: [(label: String, totals: Totals)] = []
    var currentCap: (cap: Cap, used: UInt64)?
    var capInterval: DateInterval?
    var dailyPace: Double?

    let engine: MonitorEngine
    let store: UsageStore
    let notifications = NotificationService()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var lastSeenMonth = AppModel.month(of: Date())
    @ObservationIgnored private let log = Logger(subsystem: "NetPulse", category: "usage")
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var systemEvents: SystemEvents?
    @ObservationIgnored private var capTask: Task<Void, Never>?
    @ObservationIgnored private var evaluatingCaps = false
    @ObservationIgnored private var capsDirty = false
    @ObservationIgnored private let notificationPresenter = NotificationPresenter()

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, store: Self.openStore(), live: true)
    }

    init(defaults: UserDefaults, store: UsageStore, live: Bool) {
        self.defaults = defaults
        labelStyle = defaults.string(forKey: Self.labelStyleKey).flatMap(LabelStyle.init(rawValue:)) ?? .stacked
        rateUnit = defaults.string(forKey: Self.rateUnitKey) == "bits" ? .bitsPerSecond : .bytesPerSecond
        loginOffered = defaults.bool(forKey: Self.loginOfferedKey)
        handledNameNetworks = Set((defaults.array(forKey: Self.handledNamesKey) as? [Int]) ?? []).reduce(into: []) { $0.insert(Int64($1)) }
        self.store = store
        let engine = MonitorEngine(
            store: store,
            reader: SysctlInterfaceReader(),
            detector: SystemNetworkDetector(),
            resolver: AppResolver(provider: LiveProcessInfoProvider()),
            launcher: LiveNettopLauncher(),
            nettopInterval: 10)
        self.engine = engine
        updateMenuBarText()
        guard live else { return }
        systemEvents = SystemEvents(engine: engine, isUserPaused: { [weak self] in self?.defaults.bool(forKey: Self.pausedKey) ?? false }, onTerminate: { [weak self] in self?.cancelTasks() })
        UNUserNotificationCenter.current().delegate = notificationPresenter
        capTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluateCaps()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        let startPaused = defaults.bool(forKey: Self.pausedKey)
        let fast = fastSampling
        let identityPending = LocationPermission.isUndetermined
        snapshotTask = Task { [weak self] in
            await engine.setFastSampling(fast)
            await engine.setIdentityPending(identityPending)
            await engine.start()
            if startPaused { await engine.pause() }
            for await snapshot in await engine.snapshots() {
                guard let self else { return }
                if self.snapshot != snapshot { self.snapshot = snapshot }
            }
        }
    }

    private func updateMenuBarText() {
        let speed = snapshot?.speed ?? .zero
        let format: (Double) -> String = switch labelStyle {
        case .stacked: { ByteFormatter.compactRate($0, unit: self.rateUnit) }
        case .singleLine, .downloadOnly: { ByteFormatter.rate($0, unit: self.rateUnit) }
        case .iconOnly: { _ in "" }
        }
        let text = MenuBarText(up: labelStyle == .downloadOnly ? "" : format(speed.up), down: format(speed.down), paused: snapshot?.state == .paused)
        if text != menuBarText { menuBarText = text }
    }

    private var fastSampling: Bool { popoverOpen || labelStyle != .iconOnly }

    private func updateSampling() {
        guard systemEvents != nil else { return }
        let engine = engine
        Task { [weak self] in
            guard let fast = self?.fastSampling else { return }
            await engine.setFastSampling(fast)
        }
    }

    func setPaused(_ paused: Bool) async {
        defaults.set(paused, forKey: Self.pausedKey)
        if paused { await engine.pause() } else { await engine.resume() }
    }

    func cancelTasks() {
        snapshotTask?.cancel()
        capTask?.cancel()
    }

    static func month(of date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month], from: date)
    }

    func rollHistoryMonthIfNeeded() {
        let current = Self.month(of: Date())
        guard current != lastSeenMonth else { return }
        if historyMonth == lastSeenMonth { historyMonth = current }
        lastSeenMonth = current
    }

    func scheduleRefresh() {
        Task { await refreshUsage() }
    }

    func refreshUsage() async {
        rollHistoryMonthIfNeeded()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let calendar = Calendar.current
        let now = Date()
        let boundaries = PeriodBoundaries(calendar: calendar)
        let primary = snapshot?.primaryNetwork
        let appsPeriod = appsPeriod, appsNetwork = appsNetwork
        let historyMonth = historyMonth, historyNetwork = historyNetwork
        let store = store
        do {
            let networks = try await store.networks()
            let dayInterval = boundaries.interval(.day, containing: now)
            let today = try await store.totals(network: nil, in: dayInterval)
            let topApps = try await store.appUsage(network: nil, in: dayInterval)
                .filter { $0.id != "other" }.prefix(3)
            let apps = try await store.appUsage(network: appsNetwork, in: boundaries.interval(appsPeriod, containing: now))

            let caps = try await store.caps()
            func activeCap(_ id: Int64?, _ period: CapPeriod) -> (cap: Cap, interval: DateInterval)? {
                guard let id,
                      let cap = caps.first(where: { $0.networkID == id && $0.period == period && $0.enabled && $0.limitBytes > 0 })
                else { return nil }
                let billingDay = networks.first(where: { $0.id == id })?.billingDay ?? 1
                return (cap, CapEvaluator.periodInterval(cap, billingDay: billingDay, now: now, boundaries: boundaries))
            }
            func monthlyCap(_ id: Int64?) -> (cap: Cap, interval: DateInterval)? { activeCap(id, .monthly) }
            // The popover shows whichever enabled cap of the current network is closest to its limit.
            var currentCap: (cap: Cap, used: UInt64)?
            var capInterval: DateInterval?
            for found in [activeCap(primary?.id, .daily), monthlyCap(primary?.id)].compactMap({ $0 }) {
                let used = try await store.totals(network: found.cap.networkID, in: found.interval).total
                let ratio = Double(used) / Double(found.cap.limitBytes)
                if let current = currentCap, Double(current.used) / Double(current.cap.limitBytes) >= ratio { continue }
                currentCap = (found.cap, used)
                capInterval = found.interval
            }

            let monthStart = calendar.date(from: historyMonth) ?? now
            let monthInterval = calendar.dateInterval(of: .month, for: monthStart) ?? DateInterval(start: monthStart, duration: 86_400 * 30)
            let days = try await store.daily(network: historyNetwork, in: monthInterval, calendar: calendar)
            let thisMonth = boundaries.interval(.month, containing: now)
            let lastMonth = boundaries.interval(.month, containing: thisMonth.start.addingTimeInterval(-1))
            var periodTotals: [(label: String, totals: Totals)] = []
            for (label, interval) in [
                ("Today", dayInterval), ("This week", boundaries.interval(.week, containing: now)),
                (DateText.month(thisMonth.start), thisMonth), (DateText.month(lastMonth.start), lastMonth),
            ] {
                periodTotals.append((label, try await store.totals(network: historyNetwork, in: interval)))
            }

            var dailyPace: Double?
            // A cap belongs to one network, so the pace line is drawn only when one network is selected.
            if let pace = monthlyCap(historyNetwork), (pace.interval.intersection(with: monthInterval)?.duration ?? 0) > 0 {
                let length = max(calendar.dateComponents([.day], from: pace.interval.start, to: pace.interval.end).day ?? 30, 1)
                dailyPace = Double(pace.cap.limitBytes) / Double(length)
            }

            guard generation == refreshGeneration else { return }
            let ids = Set(networks.map(\.id))
            if let appsNetwork, !ids.contains(appsNetwork) { self.appsNetwork = nil }
            if let historyNetwork, !ids.contains(historyNetwork) { self.historyNetwork = nil }
            self.networks = networks
            self.today = today
            self.topApps = Array(topApps)
            self.apps = apps
            self.currentCap = currentCap
            self.capInterval = capInterval
            self.days = days
            self.periodTotals = periodTotals
            self.dailyPace = dailyPace
            log.info("usage refreshed: networks=\(networks.count) todayBytes=\(today.total) apps=\(apps.count) days=\(days.count)")
        } catch {
            log.error("usage refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    func markLoginOffered() {
        loginOffered = true
        defaults.set(true, forKey: Self.loginOfferedKey)
    }

    func markNameHandled(_ id: Int64) {
        guard handledNameNetworks.insert(id).inserted else { return }
        defaults.set(handledNameNetworks.map { Int($0) }, forKey: Self.handledNamesKey)
    }

    func refreshNotificationStatus() async {
        notificationStatus = await notifications.status()
    }

    func saveNetwork(id: Int64, name: String, billingDay: Int) async {
        do {
            let before = try await store.networks().first { $0.id == id }?.displayName
            try await store.updateNetwork(id: id, displayName: name, billingDay: min(max(billingDay, 1), 28))
            if before != name { markNameHandled(id) }
            await refreshUsage()
            await evaluateCaps()
        } catch {
            log.error("network update failed: \(String(describing: error), privacy: .public)")
        }
    }

    func saveCap(networkID: Int64, period: CapPeriod, limitBytes: UInt64, enabled: Bool) async {
        do {
            var wasEnabled = false
            if enabled {
                wasEnabled = try await store.caps().first { $0.networkID == networkID && $0.period == period }?.enabled == true
                if !wasEnabled {
                    _ = await notifications.ensureAuthorized()
                    await refreshNotificationStatus()
                }
            }
            let existing = try await store.caps().first { $0.networkID == networkID && $0.period == period }
            var cap = existing ?? Cap(networkID: networkID, period: period, limitBytes: limitBytes, enabled: enabled)
            if cap.limitBytes != limitBytes {
                cap.lastAlertPeriodStart = nil
                cap.lastAlertThreshold = nil
            }
            cap.limitBytes = limitBytes
            cap.enabled = enabled
            try await store.saveCap(cap)
            await evaluateCaps()
            await refreshUsage()
        } catch {
            log.error("cap save failed: \(String(describing: error), privacy: .public)")
        }
    }

    func evaluateCaps() async {
        if evaluatingCaps {
            capsDirty = true
            return
        }
        evaluatingCaps = true
        defer { evaluatingCaps = false }
        repeat {
            capsDirty = false
            await evaluateCapsOnce()
        } while capsDirty
    }

    private func evaluateCapsOnce() async {
        do {
            let caps = try await store.caps().filter { $0.enabled && $0.limitBytes > 0 }
            guard !caps.isEmpty else { return }
            let networks = try await store.networks()
            let boundaries = PeriodBoundaries(calendar: Calendar.current)
            let now = Date()
            for cap in caps {
                guard let network = networks.first(where: { $0.id == cap.networkID }) else { continue }
                let interval = CapEvaluator.periodInterval(cap, billingDay: network.billingDay, now: now, boundaries: boundaries)
                let used = try await store.totals(network: cap.networkID, in: interval).total
                let result = CapEvaluator.evaluate(cap, used: used, periodStart: interval.start)
                guard let alert = result.alert else { continue }
                // The cap may have been edited while totals were loading; its alert state was reset then.
                let current = try await store.caps().first { $0.networkID == cap.networkID && $0.period == cap.period }
                guard let current, current.enabled, current.limitBytes == cap.limitBytes else {
                    capsDirty = true
                    continue
                }
                // Record the alert only once it was shown, so it still fires after notifications are allowed.
                guard await notifications.post(alert, networkName: network.displayName, resets: interval.end) else { continue }
                try await store.updateCapAlertState(
                    networkID: cap.networkID, period: cap.period,
                    lastAlertPeriodStart: result.updated.lastAlertPeriodStart, lastAlertThreshold: result.updated.lastAlertThreshold)
            }
        } catch {
            log.error("cap evaluation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func openStore() -> UsageStore {
        let log = Logger(subsystem: "NetPulse", category: "app")
        do {
            let folder = URL.applicationSupportDirectory.appending(path: "NetPulse", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try UsageStore(path: folder.appending(path: "usage.sqlite").path(percentEncoded: false))
        } catch {
            log.fault("usage database unavailable, keeping usage in memory: \(String(describing: error), privacy: .public)")
            do {
                return try UsageStore(path: ":memory:")
            } catch {
                fatalError("in-memory usage database failed: \(error)")
            }
        }
    }
}
