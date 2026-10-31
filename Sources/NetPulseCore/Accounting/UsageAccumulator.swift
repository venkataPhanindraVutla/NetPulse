import Foundation

public struct UsageRow: Sendable, Equatable {
    public let bucketStart: Int64
    public let network: NetworkKey
    public let app: AppIdentity?
    public var down: UInt64
    public var up: UInt64

    public init(bucketStart: Int64, network: NetworkKey, app: AppIdentity?, down: UInt64, up: UInt64) {
        self.bucketStart = bucketStart
        self.network = network
        self.app = app
        self.down = down
        self.up = up
    }
}

public struct UsageAccumulator: Sendable {
    private struct MergeKey: Hashable, Sendable {
        let bucketStart: Int64
        let fingerprint: String
        let appKey: String?
    }

    public static let unknownWiFi = NetworkKey(fingerprint: "wifi:unknown", kind: .wifi, suggestedName: "Wi-Fi")

    private var rows: [MergeKey: UsageRow] = [:]

    public init() {}

    public mutating func addInterface(_ d: [InterfaceDelta], networkFor: (String) -> NetworkKey, at: Date) {
        let bucket = PeriodBoundaries.bucketStart(at)
        for delta in d where delta.rx != 0 || delta.tx != 0 {
            merge(bucket: bucket, network: networkFor(delta.name), app: nil, down: delta.rx, up: delta.tx)
        }
    }

    public mutating func addApps(_ s: [(ProcessSample, AppIdentity)], network: NetworkKey, at: Date) {
        let bucket = PeriodBoundaries.bucketStart(at)
        for (sample, identity) in s where sample.bytesIn != 0 || sample.bytesOut != 0 {
            merge(bucket: bucket, network: network, app: identity, down: sample.bytesIn, up: sample.bytesOut)
        }
    }

    public mutating func drain() -> [UsageRow] {
        let drained = rows.sorted { a, b in
            if a.key.bucketStart != b.key.bucketStart { return a.key.bucketStart < b.key.bucketStart }
            if a.key.fingerprint != b.key.fingerprint { return a.key.fingerprint < b.key.fingerprint }
            switch (a.key.appKey, b.key.appKey) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x < y
            }
        }
        rows.removeAll()
        return drained.map(\.value)
    }

    private mutating func merge(bucket: Int64, network: NetworkKey, app: AppIdentity?, down: UInt64, up: UInt64) {
        let key = MergeKey(bucketStart: bucket, fingerprint: network.fingerprint, appKey: app?.key)
        if var existing = rows[key] {
            existing.down = Self.saturatingAdd(existing.down, down)
            existing.up = Self.saturatingAdd(existing.up, up)
            rows[key] = UsageRow(bucketStart: bucket, network: network, app: app, down: existing.down, up: existing.up)
        } else {
            rows[key] = UsageRow(bucketStart: bucket, network: network, app: app, down: down, up: up)
        }
    }

    private static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : sum
    }
}
