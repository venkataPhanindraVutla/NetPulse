import Foundation
import Testing
@testable import NetPulseCore

private final class FakeProvider: ProcessInfoProviding, @unchecked Sendable {
    var paths: [Int32: String] = [:]
    var responsible: [Int32: Int32] = [:]
    var bundles: [String: (id: String, name: String)] = [:]
    private(set) var pathLookups = 0

    func executablePath(pid: Int32) -> String? {
        pathLookups += 1
        return paths[pid]
    }
    func responsiblePID(pid: Int32) -> Int32? { responsible[pid] }
    func bundleInfo(atPath path: String) -> (id: String, name: String)? { bundles[path] }
}

private func sample(_ pid: Int32, _ name: String) -> ProcessSample {
    ProcessSample(pid: pid, truncatedName: name, bytesIn: 0, bytesOut: 0)
}

private let webKitNetworkingPath = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"

@Test func helperRollsUpToOutermostApp() {
    #expect(AppResolver.outermostAppBundle(forExecutable: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper") == "/Applications/Google Chrome.app")
}

@Test func noAppBundleInPath() {
    #expect(AppResolver.outermostAppBundle(forExecutable: "/opt/homebrew/bin/curl") == nil)
}

@Test func helperResolvesToParentApp() {
    let fake = FakeProvider()
    fake.paths[10] = "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    fake.bundles["/Applications/Google Chrome.app"] = (id: "com.google.Chrome", name: "Google Chrome")
    let id = AppResolver(provider: fake).resolve(sample(10, "Google Chrome H"))
    #expect(id.key == "com.google.Chrome")
    #expect(id.bundleID == "com.google.Chrome")
    #expect(id.displayName == "Google Chrome")
    #expect(id.bundlePath == "/Applications/Google Chrome.app")
    #expect(id.group == .app)
}

@Test func webkitXPCUsesResponsibleApp() {
    let fake = FakeProvider()
    fake.paths[20] = webKitNetworkingPath
    fake.paths[30] = "/Applications/Safari.app/Contents/MacOS/Safari"
    fake.responsible[20] = 30
    fake.bundles["/Applications/Safari.app"] = (id: "com.apple.Safari", name: "Safari")
    let id = AppResolver(provider: fake).resolve(sample(20, "com.apple.WebKit"))
    #expect(id.key == "com.apple.Safari")
    #expect(id.displayName == "Safari")
    #expect(id.group == .app)
}

@Test func webkitWithoutResponsibleFallsBack() {
    let fake = FakeProvider()
    fake.paths[20] = webKitNetworkingPath
    let id = AppResolver(provider: fake).resolve(sample(20, "com.apple.WebKit"))
    #expect(id.key == "com.apple.WebKit")
    #expect(id.displayName == "Apple WebKit")
    #expect(id.group == .webkit)
}

@Test func webkitResponsibleSelfFallsBack() {
    let fake = FakeProvider()
    fake.paths[20] = webKitNetworkingPath
    fake.responsible[20] = 20
    let id = AppResolver(provider: fake).resolve(sample(20, "com.apple.WebKit"))
    #expect(id.group == .webkit)
}

@Test func bareExecutableUsesProcessName() {
    let fake = FakeProvider()
    fake.paths[40] = "/opt/homebrew/bin/curl"
    let id = AppResolver(provider: fake).resolve(sample(40, "curl"))
    #expect(id.key == "proc:curl")
    #expect(id.displayName == "curl")
    #expect(id.bundleID == nil)
    #expect(id.group == .app)
}

@Test func systemDaemon() {
    let fake = FakeProvider()
    fake.paths[50] = "/usr/sbin/mDNSResponder"
    let id = AppResolver(provider: fake).resolve(sample(50, "mDNSResponder"))
    #expect(id.key == "proc:mDNSResponder")
    #expect(id.displayName == "mDNSResponder")
    #expect(id.group == .system)
}

@Test func exitedProcessUsesTruncatedName() {
    let id = AppResolver(provider: FakeProvider()).resolve(sample(60, "gone"))
    #expect(id.key == "proc:gone")
    #expect(id.group == .system)
}

@Test func resultIsCached() {
    let fake = FakeProvider()
    fake.paths[70] = "/opt/homebrew/bin/curl"
    let resolver = AppResolver(provider: fake)
    _ = resolver.resolve(sample(70, "curl"))
    _ = resolver.resolve(sample(70, "curl"))
    #expect(fake.pathLookups == 1)
}

@Test func pidReuseDoesNotReuseCache() {
    let fake = FakeProvider()
    fake.paths[80] = "/opt/homebrew/bin/curl"
    let resolver = AppResolver(provider: fake)
    #expect(resolver.resolve(sample(80, "curl")).key == "proc:curl")
    fake.paths[80] = "/usr/sbin/mDNSResponder"
    let second = resolver.resolve(sample(80, "mDNSResponder"))
    #expect(second.key == "proc:mDNSResponder")
    #expect(second.group == .system)
}

@Test func liveProviderFindsOwnExecutable() {
    #expect(LiveProcessInfoProvider().executablePath(pid: getpid()) != nil)
}

@Test func retainOnlyEvictsAbsentPIDs() {
    let fake = FakeProvider()
    fake.paths[10] = "/opt/homebrew/bin/curl"
    fake.paths[11] = "/opt/homebrew/bin/wget"
    let resolver = AppResolver(provider: fake)
    _ = resolver.resolve(sample(10, "curl"))
    _ = resolver.resolve(sample(11, "wget"))
    #expect(resolver.cachedCount == 2)
    resolver.retainOnly(pids: [11])
    #expect(resolver.cachedCount == 1)
    _ = resolver.resolve(sample(11, "wget"))
    #expect(fake.pathLookups == 2)
    _ = resolver.resolve(sample(10, "curl"))
    #expect(fake.pathLookups == 3)
}

@Test func webkitFallbackIsNotCached() {
    let fake = FakeProvider()
    fake.paths[20] = webKitNetworkingPath
    let resolver = AppResolver(provider: fake)
    #expect(resolver.resolve(sample(20, "com.apple.WebKit")).key == "com.apple.WebKit")
    fake.paths[30] = "/Applications/Safari.app/Contents/MacOS/Safari"
    fake.responsible[20] = 30
    fake.bundles["/Applications/Safari.app"] = (id: "com.apple.Safari", name: "Safari")
    #expect(resolver.resolve(sample(20, "com.apple.WebKit")).key == "com.apple.Safari")
}

@Test func exitedProcessResultIsNotCached() {
    let fake = FakeProvider()
    let resolver = AppResolver(provider: fake)
    #expect(resolver.resolve(sample(40, "curl")).group == .system)
    fake.paths[40] = "/Applications/Safari.app/Contents/MacOS/Safari"
    fake.bundles["/Applications/Safari.app"] = (id: "com.apple.Safari", name: "Safari")
    #expect(resolver.resolve(sample(40, "curl")).key == "com.apple.Safari")
}
