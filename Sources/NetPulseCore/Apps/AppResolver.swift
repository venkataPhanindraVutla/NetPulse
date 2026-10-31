import Foundation
import os

public enum AppGroup: String, Codable, Sendable {
    case app, system, webkit
}

public struct AppIdentity: Sendable, Hashable {
    public let key: String
    public let bundleID: String?
    public let displayName: String
    public let bundlePath: String?
    public let group: AppGroup

    public init(key: String, bundleID: String?, displayName: String, bundlePath: String?, group: AppGroup) {
        self.key = key
        self.bundleID = bundleID
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.group = group
    }
}

public final class AppResolver: Sendable {
    private struct CacheKey: Hashable {
        let pid: Int32
        let name: String
    }

    private let provider: any ProcessInfoProviding
    private let cache = OSAllocatedUnfairLock(initialState: [CacheKey: AppIdentity]())

    public init(provider: any ProcessInfoProviding) {
        self.provider = provider
    }

    public func resolve(_ s: ProcessSample) -> AppIdentity {
        let key = CacheKey(pid: s.pid, name: s.truncatedName)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let (identity, cacheable) = compute(s)
        if cacheable { cache.withLock { $0[key] = identity } }
        return identity
    }

    /// Drops cached identities for processes no longer reported, so the cache stays the size of the live set.
    public func retainOnly(pids: Set<Int32>) {
        cache.withLock { $0 = $0.filter { pids.contains($0.key.pid) } }
    }

    var cachedCount: Int { cache.withLock { $0.count } }

    public static func outermostAppBundle(forExecutable path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }

    /// Results that may change on a later lookup (process already gone, WebKit owner not yet known) are not cached.
    private func compute(_ s: ProcessSample) -> (AppIdentity, cacheable: Bool) {
        guard let path = provider.executablePath(pid: s.pid) else {
            return (Self.processIdentity(name: s.truncatedName, group: .system), false)
        }
        let appPath = Self.outermostAppBundle(forExecutable: path)
        let info = appPath.flatMap { provider.bundleInfo(atPath: $0) }

        if isWebKit(path: path, bundleID: info?.id) {
            if let responsible = provider.responsiblePID(pid: s.pid), responsible != s.pid,
               let responsiblePath = provider.executablePath(pid: responsible),
               let responsibleApp = Self.outermostAppBundle(forExecutable: responsiblePath),
               let responsibleInfo = provider.bundleInfo(atPath: responsibleApp) {
                return (AppIdentity(key: responsibleInfo.id, bundleID: responsibleInfo.id, displayName: responsibleInfo.name, bundlePath: responsibleApp, group: .app), true)
            }
            return (AppIdentity(key: "com.apple.WebKit", bundleID: "com.apple.WebKit", displayName: "Apple WebKit", bundlePath: nil, group: .webkit), false)
        }

        let executableName = (path as NSString).lastPathComponent
        if let appPath {
            if let info {
                return (AppIdentity(key: info.id, bundleID: info.id, displayName: info.name, bundlePath: appPath, group: .app), true)
            }
            let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            return (AppIdentity(key: "proc:" + executableName, bundleID: nil, displayName: name, bundlePath: appPath, group: .app), true)
        }
        let isSystem = ["/usr/", "/System/", "/sbin/"].contains { path.hasPrefix($0) }
        return (Self.processIdentity(name: executableName, group: isSystem ? .system : .app), true)
    }

    private func isWebKit(path: String, bundleID: String?) -> Bool {
        path.contains("/WebKit.framework/") || (bundleID?.hasPrefix("com.apple.WebKit.") ?? false)
    }

    private static func processIdentity(name: String, group: AppGroup) -> AppIdentity {
        AppIdentity(key: "proc:" + name, bundleID: nil, displayName: name, bundlePath: nil, group: group)
    }
}
