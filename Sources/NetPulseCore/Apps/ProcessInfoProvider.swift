import Darwin
import Foundation

public protocol ProcessInfoProviding: Sendable {
    func executablePath(pid: Int32) -> String?
    func responsiblePID(pid: Int32) -> Int32?
    func bundleInfo(atPath: String) -> (id: String, name: String)?
}

public struct LiveProcessInfoProvider: ProcessInfoProviding {
    private typealias ResponsibleFn = @convention(c) (Int32) -> Int32

    private static let responsibleFn: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    public init() {}

    public func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func responsiblePID(pid: Int32) -> Int32? {
        guard let fn = Self.responsibleFn else { return nil }
        let result = fn(pid)
        return result > 0 && result != pid ? result : nil
    }

    public func bundleInfo(atPath path: String) -> (id: String, name: String)? {
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return (id, name)
    }
}
