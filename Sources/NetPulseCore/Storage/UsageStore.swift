import Foundation

public struct StoredNetwork: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let key: NetworkKey
    public var displayName: String
    public var billingDay: Int
}

public struct AppUsage: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let bundlePath: String?
    public let group: AppGroup?
    public let down: UInt64
    public let up: UInt64
}

public struct Totals: Sendable, Equatable {
    public var down: UInt64
    public var up: UInt64
    public var total: UInt64 { down + up }

    public init(down: UInt64, up: UInt64) {
        self.down = down
        self.up = up
    }
}

public struct DayUsage: Sendable, Identifiable {
    public let id: Date
    public let totals: Totals
    public let hasGap: Bool
}

public actor UsageStore {
    private let db: SQLiteDatabase

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        let version = try db.query("PRAGMA user_version", []).first.flatMap { row -> Int64? in
            if case .int(let v)? = row.first { return v }
            return nil
        } ?? 0
        if version < 1 { try createSchema(db) }
        if version < 2 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
                PRAGMA user_version = 2;
                """)
            }
        }
        try db.execute("PRAGMA journal_mode = WAL")
    }

    private static func createSchema(_ db: SQLiteDatabase) throws {
        try db.transaction {
            try db.execute("""
            CREATE TABLE networks(id INTEGER PRIMARY KEY, fingerprint TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, display_name TEXT NOT NULL, billing_day INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE apps(id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, bundle_id TEXT, display_name TEXT NOT NULL, bundle_path TEXT, grp TEXT NOT NULL);
            INSERT INTO apps(id, key, display_name, grp) VALUES (0, '__total__', 'Total', 'system');
            CREATE TABLE usage(bucket_start INTEGER NOT NULL, network_id INTEGER NOT NULL, app_id INTEGER NOT NULL, down INTEGER NOT NULL, up INTEGER NOT NULL, PRIMARY KEY(bucket_start, network_id, app_id)) WITHOUT ROWID;
            CREATE TABLE gaps(start INTEGER NOT NULL, end INTEGER NOT NULL, reason TEXT NOT NULL);
            CREATE TABLE caps(network_id INTEGER NOT NULL, period TEXT NOT NULL, limit_bytes INTEGER NOT NULL, enabled INTEGER NOT NULL, last_alert_period_start INTEGER, last_alert_threshold INTEGER, PRIMARY KEY(network_id, period));
            PRAGMA user_version = 1;
            """)
        }
    }

    public func write(_ rows: [UsageRow]) throws {
        guard !rows.isEmpty else { return }
        let upsert = """
        INSERT INTO usage(bucket_start, network_id, app_id, down, up) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(bucket_start, network_id, app_id) DO UPDATE SET down = down + excluded.down, up = up + excluded.up
        """
        try db.transaction {
            var networkIDs: [String: Int64] = [:]
            var appIDs: [String: Int64] = [:]
            for row in rows {
                let networkID: Int64
                if let cached = networkIDs[row.network.fingerprint] {
                    networkID = cached
                } else {
                    networkID = try upsertNetwork(row.network)
                    networkIDs[row.network.fingerprint] = networkID
                }
                var appID: Int64 = 0
                if let app = row.app {
                    if let cached = appIDs[app.key] {
                        appID = cached
                    } else {
                        appID = try upsertApp(app)
                        appIDs[app.key] = appID
                    }
                }
                try db.query(upsert, [
                    .int(row.bucketStart), .int(networkID), .int(appID),
                    .int(Self.clamp(row.down)), .int(Self.clamp(row.up)),
                ])
            }
        }
    }

    public func recordGap(start: Date, end: Date, reason: String) throws {
        try db.query("INSERT INTO gaps(start, end, reason) VALUES (?, ?, ?)", [
            .int(Int64(start.timeIntervalSince1970)), .int(Int64(end.timeIntervalSince1970)), .text(reason),
        ])
    }

    /// Gaps with these reasons mean traffic went unmeasured; the others (sleep, nettop restarts) only interrupt per-app detail.
    static let unmonitoredGapReasons = ["not running", "paused"]

    func gaps() throws -> [(start: Date, end: Date, reason: String)] {
        try db.query("SELECT start, end, reason FROM gaps ORDER BY start", []).compactMap { row in
            guard case .int(let s) = row[0], case .int(let e) = row[1], case .text(let reason) = row[2] else { return nil }
            return (Date(timeIntervalSince1970: TimeInterval(s)), Date(timeIntervalSince1970: TimeInterval(e)), reason)
        }
    }

    /// The last moment the engine was known to be monitoring; on the next start the time since is recorded as a gap.
    public func setHeartbeat(_ date: Date) throws {
        try db.query("INSERT INTO meta(key, value) VALUES ('heartbeat', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [
            .int(Int64(date.timeIntervalSince1970.rounded(.down))),
        ])
    }

    public func heartbeat() throws -> Date? {
        guard case .int(let value)? = try db.query("SELECT value FROM meta WHERE key = 'heartbeat'", []).first?.first else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    public func networks() throws -> [StoredNetwork] {
        try db.query("SELECT id, fingerprint, kind, display_name, billing_day FROM networks ORDER BY id", []).compactMap { row in
            guard case .int(let id) = row[0], case .text(let fingerprint) = row[1], case .text(let kindRaw) = row[2],
                  case .text(let name) = row[3], case .int(let billing) = row[4],
                  let kind = InterfaceKind(rawValue: kindRaw) else { return nil }
            return StoredNetwork(
                id: id,
                key: NetworkKey(fingerprint: fingerprint, kind: kind, suggestedName: name),
                displayName: name,
                billingDay: Int(billing)
            )
        }
    }

    public func updateNetwork(id: Int64, displayName: String, billingDay: Int) throws {
        try db.query("UPDATE networks SET display_name = ?, billing_day = ? WHERE id = ?", [
            .text(displayName), .int(Int64(billingDay)), .int(id),
        ])
    }

    /// Folds one network's history into another, e.g. a router-fingerprint row into the SSID row of the same Wi-Fi.
    /// Usage adds up per bucket and app, caps move only for periods the target has none for, and a rename or billing
    /// day carries over only while the target still has its defaults.
    public func mergeNetwork(from source: NetworkKey, into target: NetworkKey) throws {
        guard source.fingerprint != target.fingerprint else { return }
        try db.transaction {
            let rows = try db.query("SELECT id, display_name, billing_day FROM networks WHERE fingerprint = ?", [.text(source.fingerprint)])
            guard let from = rows.first, case .int(let fromID) = from[0] else { return }
            let into = try upsertNetwork(target)
            try db.query("""
            INSERT INTO usage(bucket_start, network_id, app_id, down, up)
            SELECT bucket_start, ?, app_id, down, up FROM usage WHERE network_id = ?
            ON CONFLICT(bucket_start, network_id, app_id) DO UPDATE SET down = down + excluded.down, up = up + excluded.up
            """, [.int(into), .int(fromID)])
            try db.query("DELETE FROM usage WHERE network_id = ?", [.int(fromID)])
            try db.query("UPDATE OR IGNORE caps SET network_id = ? WHERE network_id = ?", [.int(into), .int(fromID)])
            try db.query("DELETE FROM caps WHERE network_id = ?", [.int(fromID)])
            if case .text(let name) = from[1], name != source.suggestedName {
                try db.query("UPDATE networks SET display_name = ? WHERE id = ? AND display_name = ?", [
                    .text(name), .int(into), .text(target.suggestedName),
                ])
            }
            if case .int(let billing) = from[2], billing != 1 {
                try db.query("UPDATE networks SET billing_day = ? WHERE id = ? AND billing_day = 1", [.int(billing), .int(into)])
            }
            try db.query("DELETE FROM networks WHERE id = ?", [.int(fromID)])
        }
    }

    public func caps() throws -> [Cap] {
        try db.query("""
        SELECT network_id, period, limit_bytes, enabled, last_alert_period_start, last_alert_threshold
        FROM caps ORDER BY network_id, period
        """, []).compactMap { row in
            guard case .int(let network) = row[0], case .text(let periodRaw) = row[1], let period = CapPeriod(rawValue: periodRaw),
                  case .int(let limit) = row[2], case .int(let enabled) = row[3] else { return nil }
            var lastStart: Date?
            if case .int(let s) = row[4] { lastStart = Date(timeIntervalSince1970: TimeInterval(s)) }
            var lastThreshold: Int?
            if case .int(let t) = row[5] { lastThreshold = Int(t) }
            return Cap(
                networkID: network, period: period, limitBytes: limit > 0 ? UInt64(limit) : 0, enabled: enabled != 0,
                lastAlertPeriodStart: lastStart, lastAlertThreshold: lastThreshold
            )
        }
    }

    public func saveCap(_ cap: Cap) throws {
        try db.query("""
        INSERT INTO caps(network_id, period, limit_bytes, enabled, last_alert_period_start, last_alert_threshold) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(network_id, period) DO UPDATE SET limit_bytes = excluded.limit_bytes, enabled = excluded.enabled,
            last_alert_period_start = excluded.last_alert_period_start, last_alert_threshold = excluded.last_alert_threshold
        """, [
            .int(cap.networkID), .text(cap.period.rawValue), .int(Self.clamp(cap.limitBytes)), .int(cap.enabled ? 1 : 0),
            cap.lastAlertPeriodStart.map { .int(Int64($0.timeIntervalSince1970.rounded(.down))) } ?? .null,
            cap.lastAlertThreshold.map { .int(Int64($0)) } ?? .null,
        ])
    }

    public func updateCapAlertState(networkID: Int64, period: CapPeriod, lastAlertPeriodStart: Date?, lastAlertThreshold: Int?) throws {
        try db.query("""
        UPDATE caps SET last_alert_period_start = ?, last_alert_threshold = ? WHERE network_id = ? AND period = ?
        """, [
            lastAlertPeriodStart.map { .int(Int64($0.timeIntervalSince1970.rounded(.down))) } ?? .null,
            lastAlertThreshold.map { .int(Int64($0)) } ?? .null,
            .int(networkID), .text(period.rawValue),
        ])
    }

    public func totals(network: Int64?, in interval: DateInterval) throws -> Totals {
        var sql = "SELECT COALESCE(SUM(down), 0), COALESCE(SUM(up), 0) FROM usage WHERE app_id = 0 AND bucket_start >= ? AND bucket_start < ?"
        var binds = Self.range(interval)
        if let network {
            sql += " AND network_id = ?"
            binds.append(.int(network))
        }
        let row = try db.query(sql, binds).first ?? []
        return Totals(down: Self.unsigned(row, 0), up: Self.unsigned(row, 1))
    }

    public func appUsage(network: Int64?, in interval: DateInterval) throws -> [AppUsage] {
        var filter = "bucket_start >= ? AND bucket_start < ?"
        var binds = Self.range(interval)
        if let network {
            filter += " AND network_id = ?"
            binds.append(.int(network))
        }

        let appRows = try db.query("""
        SELECT a.key, a.display_name, a.bundle_path, a.grp, SUM(u.down), SUM(u.up)
        FROM usage u JOIN apps a ON a.id = u.app_id
        WHERE u.app_id != 0 AND \(filter.replacingOccurrences(of: "bucket_start", with: "u.bucket_start").replacingOccurrences(of: "network_id", with: "u.network_id"))
        GROUP BY a.id
        """, binds)

        var result: [AppUsage] = appRows.compactMap { row in
            guard case .text(let key) = row[0], case .text(let name) = row[1], case .text(let group) = row[3] else { return nil }
            var path: String?
            if case .text(let p) = row[2] { path = p }
            return AppUsage(
                id: key, displayName: name, bundlePath: path, group: AppGroup(rawValue: group),
                down: Self.unsigned(row, 4), up: Self.unsigned(row, 5)
            )
        }
        result.sort { ($0.down &+ $0.up, $1.id) > ($1.down &+ $1.up, $0.id) }

        let perNetwork = try db.query("""
        SELECT network_id,
               COALESCE(SUM(CASE WHEN app_id = 0 THEN down ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN app_id = 0 THEN up ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN app_id != 0 THEN down ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN app_id != 0 THEN up ELSE 0 END), 0)
        FROM usage WHERE \(filter) GROUP BY network_id
        """, binds)
        var otherDown: UInt64 = 0
        var otherUp: UInt64 = 0
        for row in perNetwork {
            let totalDown = Self.unsigned(row, 1), totalUp = Self.unsigned(row, 2)
            let appsDown = Self.unsigned(row, 3), appsUp = Self.unsigned(row, 4)
            otherDown = Self.saturatingAdd(otherDown, totalDown > appsDown ? totalDown - appsDown : 0)
            otherUp = Self.saturatingAdd(otherUp, totalUp > appsUp ? totalUp - appsUp : 0)
        }
        if otherDown > 0 || otherUp > 0 {
            result.append(AppUsage(id: "other", displayName: "Other / system", bundlePath: nil, group: nil, down: otherDown, up: otherUp))
        }
        return result
    }

    public func daily(network: Int64?, in interval: DateInterval, calendar: Calendar) throws -> [DayUsage] {
        var sql = "SELECT bucket_start, down, up FROM usage WHERE app_id = 0 AND bucket_start >= ? AND bucket_start < ?"
        var binds = Self.range(interval)
        if let network {
            sql += " AND network_id = ?"
            binds.append(.int(network))
        }
        var perDay: [Date: Totals] = [:]
        for row in try db.query(sql, binds) {
            guard case .int(let bucket) = row[0] else { continue }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(bucket)))
            var t = perDay[day] ?? Totals(down: 0, up: 0)
            t.down = Self.saturatingAdd(t.down, Self.unsigned(row, 1))
            t.up = Self.saturatingAdd(t.up, Self.unsigned(row, 2))
            perDay[day] = t
        }

        let reasons = Self.unmonitoredGapReasons.map { _ in "?" }.joined(separator: ", ")
        let gaps = try db.query("SELECT start, end FROM gaps WHERE start < ? AND end > ? AND reason IN (\(reasons))", [
            .int(Int64(interval.end.timeIntervalSince1970.rounded(.up))), .int(Int64(interval.start.timeIntervalSince1970.rounded(.down))),
        ] + Self.unmonitoredGapReasons.map(SQLiteValue.text)).compactMap { row -> (Double, Double)? in
            guard case .int(let s) = row[0], case .int(let e) = row[1] else { return nil }
            return (Double(s), Double(e))
        }

        var days: [DayUsage] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let lower = day.timeIntervalSince1970, upper = next.timeIntervalSince1970
            let hasGap = gaps.contains { $0.0 < upper && $0.1 > lower }
            days.append(DayUsage(id: day, totals: perDay[day] ?? Totals(down: 0, up: 0), hasGap: hasGap))
            day = next
        }
        return days
    }

    private func upsertNetwork(_ key: NetworkKey) throws -> Int64 {
        try db.query(
            "INSERT INTO networks(fingerprint, kind, display_name) VALUES (?, ?, ?) ON CONFLICT(fingerprint) DO UPDATE SET kind = excluded.kind",
            [.text(key.fingerprint), .text(key.kind.rawValue), .text(key.suggestedName)]
        )
        let rows = try db.query("SELECT id FROM networks WHERE fingerprint = ?", [.text(key.fingerprint)])
        guard case .int(let id)? = rows.first?.first else { throw SQLiteError(code: -1, message: "network row missing") }
        return id
    }

    private func upsertApp(_ app: AppIdentity) throws -> Int64 {
        try db.query("""
        INSERT INTO apps(key, bundle_id, display_name, bundle_path, grp) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET bundle_id = excluded.bundle_id, display_name = excluded.display_name, bundle_path = excluded.bundle_path, grp = excluded.grp
        """, [
            .text(app.key),
            app.bundleID.map(SQLiteValue.text) ?? .null,
            .text(app.displayName),
            app.bundlePath.map(SQLiteValue.text) ?? .null,
            .text(app.group.rawValue),
        ])
        let rows = try db.query("SELECT id FROM apps WHERE key = ?", [.text(app.key)])
        guard case .int(let id)? = rows.first?.first else { throw SQLiteError(code: -1, message: "app row missing") }
        return id
    }

    private static func range(_ interval: DateInterval) -> [SQLiteValue] {
        [.int(Int64(interval.start.timeIntervalSince1970.rounded(.down))), .int(Int64(interval.end.timeIntervalSince1970.rounded(.down)))]
    }

    private static func clamp(_ v: UInt64) -> Int64 {
        v > UInt64(Int64.max) ? Int64.max : Int64(v)
    }

    private static func unsigned(_ row: [SQLiteValue], _ index: Int) -> UInt64 {
        if index < row.count, case .int(let v) = row[index], v > 0 { return UInt64(v) }
        return 0
    }

    private static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : sum
    }
}
