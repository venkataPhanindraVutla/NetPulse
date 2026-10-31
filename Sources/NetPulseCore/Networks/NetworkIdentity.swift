public struct NetworkObservation: Sendable, Equatable {
    public let interfaceName: String
    public let kind: InterfaceKind
    public let ssid: String?
    public let gatewayMAC: String?
    public let interfaceMAC: String?

    public init(interfaceName: String, kind: InterfaceKind, ssid: String?, gatewayMAC: String?, interfaceMAC: String?) {
        self.interfaceName = interfaceName
        self.kind = kind
        self.ssid = ssid
        self.gatewayMAC = gatewayMAC
        self.interfaceMAC = interfaceMAC
    }
}

public struct NetworkKey: Sendable, Hashable, Codable {
    public let fingerprint: String
    public let kind: InterfaceKind
    public let suggestedName: String

    public init(fingerprint: String, kind: InterfaceKind, suggestedName: String) {
        self.fingerprint = fingerprint
        self.kind = kind
        self.suggestedName = suggestedName
    }
}

public enum NetworkIdentity {
    public static func key(for o: NetworkObservation) -> NetworkKey? {
        switch o.kind {
        case .wifi:
            if let ssid = o.ssid, !ssid.isEmpty {
                return NetworkKey(fingerprint: "wifi:ssid:\(ssid)", kind: .wifi, suggestedName: ssid)
            }
            return gatewayKey(for: o)
        case .ethernet:
            guard let mac = normalizedMAC(o.interfaceMAC) else { return nil }
            return NetworkKey(fingerprint: "eth:\(mac)", kind: .ethernet, suggestedName: "Ethernet (\(o.interfaceName))")
        default:
            return nil
        }
    }

    /// The router-fingerprint key a Wi-Fi network gets while its SSID is unreadable.
    public static func gatewayKey(for o: NetworkObservation) -> NetworkKey? {
        guard o.kind == .wifi, let mac = normalizedMAC(o.gatewayMAC) else { return nil }
        return NetworkKey(fingerprint: "wifi:gw:\(mac)", kind: .wifi, suggestedName: "Wi-Fi network")
    }

    static func normalizedMAC(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [String] = []
        for part in parts {
            guard (1...2).contains(part.count), UInt8(part, radix: 16) != nil else { return nil }
            out.append(part.count == 1 ? "0" + part.lowercased() : part.lowercased())
        }
        return out.joined(separator: ":")
    }
}
