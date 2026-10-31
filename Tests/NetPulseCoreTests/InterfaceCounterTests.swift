import Foundation
import Testing
@testable import NetPulseCore

@Test func classifier() {
    #expect(InterfaceClassifier.kind(bsdName: "lo0", scType: nil) == .loopback)
    #expect(InterfaceClassifier.kind(bsdName: "utun3", scType: nil) == .virtual)
    #expect(InterfaceClassifier.kind(bsdName: "awdl0", scType: nil) == .virtual)
    #expect(InterfaceClassifier.kind(bsdName: "bridge0", scType: "Bridge") == .virtual)
    #expect(InterfaceClassifier.kind(bsdName: "en0", scType: "IEEE80211") == .wifi)
    #expect(InterfaceClassifier.kind(bsdName: "en5", scType: "Ethernet") == .ethernet)
    #expect(InterfaceClassifier.kind(bsdName: "en9", scType: nil) == .other)
}

@Test func liveReadIsSane() throws {
    let c = try SysctlInterfaceReader().read()
    #expect(c.contains { $0.kind == .loopback })
    #expect(c.contains { $0.kind.isPhysical })
    #expect(Set(c.map(\.name)).count == c.count)
}

@Test func systemConfigurationTypesAreCachedWhileInterfacesAreStable() throws {
    let calls = NSLock()
    nonisolated(unsafe) var count = 0
    let reader = SysctlInterfaceReader(scTypes: {
        calls.withLock { count += 1 }
        return ["lo0": "Loopback"]
    })
    _ = try reader.read()
    let second = try reader.read()
    #expect(calls.withLock { count } == 1)
    #expect(second.contains { $0.kind == .loopback })
}

private final class CacheProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: Duration = .zero
    private var lookups = 0
    var types: [String: String] = ["lo0": "Loopback", "en0": "IEEE80211"]
    private let base = ContinuousClock.now

    func advance(_ d: Duration) { lock.withLock { offset += d } }
    var lookupCount: Int { lock.withLock { lookups } }
    func now() -> ContinuousClock.Instant { lock.withLock { base + offset } }
    func lookup() -> [String: String] { lock.withLock { lookups += 1; return types } }
}

@Test func typeCacheInvalidatedWhenInterfaceSetChanges() {
    let probe = CacheProbe()
    let cache = TypeCache(now: { probe.now() })
    _ = cache.types(for: ["lo0", "en0"], lookup: probe.lookup)
    _ = cache.types(for: ["lo0", "en0", "utun3"], lookup: probe.lookup)
    #expect(probe.lookupCount == 2)
    _ = cache.types(for: ["lo0", "en0", "utun3"], lookup: probe.lookup)
    #expect(probe.lookupCount == 2)
}

@Test func typeCacheRetriesMissingTypeAfterRateLimit() {
    let probe = CacheProbe()
    let cache = TypeCache(now: { probe.now() })
    let names: Set<String> = ["lo0", "en0", "en7"]
    #expect(cache.types(for: names, lookup: probe.lookup)["en7"] == nil)
    probe.types["en7"] = "Ethernet"
    probe.advance(.seconds(1))
    #expect(cache.types(for: names, lookup: probe.lookup)["en7"] == nil)
    probe.advance(TypeCache.missingTypeRetry)
    #expect(cache.types(for: names, lookup: probe.lookup)["en7"] == "Ethernet")
    #expect(probe.lookupCount == 2)
    probe.advance(TypeCache.missingTypeRetry)
    _ = cache.types(for: names, lookup: probe.lookup)
    #expect(probe.lookupCount == 2)
}

@Test func typeCachePermanentlyUntypedNameIsRateLimited() {
    let probe = CacheProbe()
    let cache = TypeCache(now: { probe.now() })
    let names: Set<String> = ["lo0", "en0", "en9", "utun0", "awdl0"]
    for _ in 0..<30 {
        _ = cache.types(for: names, lookup: probe.lookup)
        probe.advance(.seconds(1))
    }
    let expected = 30 / Int(TypeCache.missingTypeRetry.components.seconds)
    #expect(probe.lookupCount <= expected + 1)
    #expect(probe.lookupCount >= 2)
}

@Test func typeCacheIgnoresVirtualAndLoopbackWithoutTypes() {
    let probe = CacheProbe()
    let cache = TypeCache(now: { probe.now() })
    let names: Set<String> = ["lo0", "en0", "utun0", "awdl0", "bridge0", "gif0"]
    for _ in 0..<10 {
        _ = cache.types(for: names, lookup: probe.lookup)
        probe.advance(.seconds(1))
    }
    #expect(probe.lookupCount == 1)
}

@Test func hypervisorAndCaptureInterfacesAreVirtual() {
    for name in ["vmenet0", "vnic0", "feth3", "pktap0", "bridge100"] {
        #expect(InterfaceClassifier.kind(bsdName: name, scType: nil) == .virtual)
    }
}

@Test func typeCacheStopsRetryingAMissingNameAfterFiveAttempts() {
    let probe = CacheProbe()
    let cache = TypeCache(now: { probe.now() })
    let names: Set<String> = ["lo0", "en0", "en9"]
    for _ in 0..<19 {
        _ = cache.types(for: names, lookup: probe.lookup)
        probe.advance(TypeCache.missingTypeRetry)
    }
    #expect(probe.lookupCount == TypeCache.maxMissingAttempts)
    _ = cache.types(for: names.union(["en10"]), lookup: probe.lookup)
    probe.advance(TypeCache.missingTypeRetry)
    _ = cache.types(for: names.union(["en10"]), lookup: probe.lookup)
    #expect(probe.lookupCount == TypeCache.maxMissingAttempts + 2)
}
