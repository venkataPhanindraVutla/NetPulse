import Darwin
import Foundation
import os
import SystemConfiguration

public enum InterfaceReadError: Error, Equatable {
    case sysctlFailed(errno: Int32)
}

public struct SysctlInterfaceReader: InterfaceCounterReading {
    private let scTypes: @Sendable () -> [String: String]
    private let typeCache = TypeCache()

    public init() {
        self.scTypes = Self.systemConfigurationTypes
    }

    init(scTypes: @escaping @Sendable () -> [String: String]) {
        self.scTypes = scTypes
    }

    public func read() throws -> [InterfaceCounter] {
        let buffer = try Self.interfaceList()
        var seen = Set<String>()
        var entries: [(name: String, rx: UInt64, tx: UInt64, isUp: Bool)] = []
        let header = MemoryLayout<if_msghdr2>.size

        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= raw.count {
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length > 0, offset + length <= raw.count else { break }
                defer { offset += length }
                let type = raw.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
                guard Int32(type) == RTM_IFINFO2, length >= header else { continue }
                let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                guard if_indextoname(UInt32(msg.ifm_index), &nameBuf) != nil else { continue }
                let name = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard seen.insert(name).inserted else { continue }
                entries.append((name, msg.ifm_data.ifi_ibytes, msg.ifm_data.ifi_obytes, msg.ifm_flags & IFF_UP != 0))
            }
        }
        // SCNetworkInterfaceCopyAll dominates a read's cost, so types are cached while the interface set is stable.
        let types = typeCache.types(for: seen, lookup: scTypes)
        return entries.map {
            InterfaceCounter(
                name: $0.name,
                kind: InterfaceClassifier.kind(bsdName: $0.name, scType: types[$0.name]),
                rxBytes: $0.rx,
                txBytes: $0.tx,
                isUp: $0.isUp
            )
        }
    }

    private static func interfaceList() throws -> [UInt8] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
                throw InterfaceReadError.sysctlFailed(errno: errno)
            }
            var buffer = [UInt8](repeating: 0, count: size + size / 8 + 512)
            size = buffer.count
            if sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 {
                return Array(buffer[..<size])
            }
            guard errno == ENOMEM else { throw InterfaceReadError.sysctlFailed(errno: errno) }
        }
        throw InterfaceReadError.sysctlFailed(errno: ENOMEM)
    }

    private static func systemConfigurationTypes() -> [String: String] {
        var map: [String: String] = [:]
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for interface in all {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            map[name] = type
        }
        return map
    }
}

final class TypeCache: Sendable {
    static let maxAge: Duration = .seconds(60)
    static let missingTypeRetry: Duration = .seconds(3)
    static let maxMissingAttempts = 5

    private struct Entry: Sendable {
        let names: Set<String>
        let types: [String: String]
        let at: ContinuousClock.Instant
        let retryMissing: Bool
        let misses: [String: Int]
    }

    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = OSAllocatedUnfairLock<Entry?>(initialState: nil)

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// A name that is neither loopback nor virtual but has no SystemConfiguration type may be an adapter SC hasn't
    /// registered yet; it would classify as `.other` and its bytes would be dropped, so such a miss is re-checked soon.
    /// A name still untyped after `maxMissingAttempts` lookups is left to the normal refresh until the name set changes.
    func types(for names: Set<String>, lookup: () -> [String: String]) -> [String: String] {
        let instant = now()
        let cached = state.withLock { $0 }
        if let cached, cached.names == names {
            let age = cached.at.duration(to: instant)
            if age < (cached.retryMissing ? Self.missingTypeRetry : Self.maxAge) { return cached.types }
        }
        let types = lookup()
        let previous = cached?.names == names ? cached?.misses ?? [:] : [:]
        var misses: [String: Int] = [:]
        for name in names where types[name] == nil && InterfaceClassifier.kind(bsdName: name, scType: nil) == .other {
            misses[name] = (previous[name] ?? 0) + 1
        }
        let entry = Entry(names: names, types: types, at: instant, retryMissing: misses.values.contains { $0 < Self.maxMissingAttempts }, misses: misses)
        state.withLock { $0 = entry }
        return types
    }
}
