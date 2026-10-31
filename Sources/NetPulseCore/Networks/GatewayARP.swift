import Darwin
import Foundation

enum GatewayARP {
    static func mac(forRouter router: String, in buffer: [UInt8]) -> String? {
        var addr = in_addr()
        guard inet_pton(AF_INET, router, &addr) == 1 else { return nil }
        let target = withUnsafeBytes(of: addr) { Array($0) }
        let header = MemoryLayout<rt_msghdr>.size

        return buffer.withUnsafeBytes { raw -> String? in
            var offset = 0
            while offset + 4 <= raw.count {
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length > 0, offset + length <= raw.count else { return nil }
                defer { offset += length }
                guard length >= header else { continue }
                let end = offset + length
                let inarp = offset + header
                guard inarp + 8 <= end else { continue }
                let inarpLen = Int(raw[inarp])
                guard inarpLen >= 8, Int32(raw[inarp + 1]) == AF_INET,
                      Array(raw[(inarp + 4)..<(inarp + 8)]) == target else { continue }
                let dl = inarp + roundUp(inarpLen)
                guard dl + 8 <= end, Int32(raw[dl + 1]) == AF_LINK else { continue }
                let nameLen = Int(raw[dl + 5])
                let addrLen = Int(raw[dl + 6])
                let start = dl + 8 + nameLen
                guard addrLen == 6, start + 6 <= end else { continue }
                return Array(raw[start..<(start + 6)]).map { String(format: "%02x", $0) }.joined(separator: ":")
            }
            return nil
        }
    }

    static func routeTable() -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size + size / 8 + 512)
            size = buffer.count
            if sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 {
                return Array(buffer[..<size])
            }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    private static func roundUp(_ length: Int) -> Int {
        length > 0 ? (length + 3) & ~3 : 4
    }
}
