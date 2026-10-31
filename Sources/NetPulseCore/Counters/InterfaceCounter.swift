public enum InterfaceKind: String, Codable, Sendable {
    case wifi, ethernet, loopback, virtual, other
}

extension InterfaceKind {
    public var isPhysical: Bool { self == .wifi || self == .ethernet }
}

public struct InterfaceCounter: Sendable, Equatable {
    public let name: String
    public let kind: InterfaceKind
    public let rxBytes: UInt64
    public let txBytes: UInt64
    public let isUp: Bool

    public init(name: String, kind: InterfaceKind, rxBytes: UInt64, txBytes: UInt64, isUp: Bool) {
        self.name = name
        self.kind = kind
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.isUp = isUp
    }
}

public enum InterfaceClassifier {
    static let virtualPrefixes = ["utun", "bridge", "awdl", "llw", "ap", "anpi", "gif", "stf", "ipsec", "vmenet", "vnic", "feth", "pktap"]

    public static func kind(bsdName: String, scType: String?) -> InterfaceKind {
        if bsdName.hasPrefix("lo") { return .loopback }
        if virtualPrefixes.contains(where: bsdName.hasPrefix) { return .virtual }
        switch scType {
        case "IEEE80211": return .wifi
        case "Ethernet": return .ethernet
        case "Bridge": return .virtual
        default: return .other
        }
    }
}

public protocol InterfaceCounterReading: Sendable {
    func read() throws -> [InterfaceCounter]
}
