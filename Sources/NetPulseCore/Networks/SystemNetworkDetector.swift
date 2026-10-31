import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

public protocol NetworkDetecting: Sendable {
    func primary() -> NetworkObservation?
    func activePhysical() -> [NetworkObservation]
    func changes() -> AsyncStream<Void>
}

public final class SystemNetworkDetector: NetworkDetecting {
    private static let globalIPv4 = "State:/Network/Global/IPv4"
    /// AirPort covers Wi-Fi joins; IPv4 catches a second interface (e.g. Ethernet) getting its DHCP lease later.
    static let notificationPatterns = ["State:/Network/Interface/.*/AirPort", "State:/Network/Interface/.*/IPv4"]

    public init() {}

    public func primary() -> NetworkObservation? {
        guard let store = SCDynamicStoreCreate(nil, "NetPulse" as CFString, nil, nil) else { return nil }
        let global = SCDynamicStoreCopyValue(store, Self.globalIPv4 as CFString) as? [String: Any]
        if let name = global?["PrimaryInterface"] as? String {
            let types = Self.systemConfigurationTypes()
            let kind = InterfaceClassifier.kind(bsdName: name, scType: types[name])
            if kind.isPhysical {
                return observation(name: name, kind: kind, router: global?["Router"] as? String)
            }
        }
        let candidates = routedCandidates()
        let choice = Self.chooseUplink(candidates.map(\.candidate))
        guard let pick = candidates.first(where: { $0.candidate.name == choice }) else { return nil }
        return observation(name: pick.candidate.name, kind: pick.kind, router: pick.router)
    }

    struct UplinkCandidate: Equatable {
        let name: String
        let hasRouter: Bool
        let serviceOrderIndex: Int?
    }

    static func serviceID(fromStateKey key: String) -> String? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "State:", parts[2] == "Service", !parts[3].isEmpty else { return nil }
        return String(parts[3])
    }

    static func serviceOrderIndices(entries: [(key: String, interface: String)], order: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for entry in entries {
            guard let id = serviceID(fromStateKey: entry.key), let index = order.firstIndex(of: id) else { continue }
            result[entry.interface] = min(index, result[entry.interface] ?? .max)
        }
        return result
    }

    static func chooseUplink(_ candidates: [UplinkCandidate]) -> String? {
        candidates
            .filter(\.hasRouter)
            .min { ($0.serviceOrderIndex ?? .max) < ($1.serviceOrderIndex ?? .max) }?
            .name
    }

    public func activePhysical() -> [NetworkObservation] {
        routedCandidates().map { observation(name: $0.candidate.name, kind: $0.kind, router: $0.router) }
    }

    private struct Resolved {
        let candidate: UplinkCandidate
        let kind: InterfaceKind
        let router: String?
    }

    private func routedCandidates() -> [Resolved] {
        guard let counters = try? SysctlInterfaceReader().read() else { return [] }
        let withIPv4 = Self.interfacesWithIPv4()
        let store = SCDynamicStoreCreate(nil, "NetPulse" as CFString, nil, nil)
        let global = store.flatMap { SCDynamicStoreCopyValue($0, Self.globalIPv4 as CFString) } as? [String: Any]
        var serviceRouters: [String: String] = [:]
        var entries: [(key: String, interface: String)] = []
        var order: [String] = []
        if let store {
            order = (SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any])?["ServiceOrder"] as? [String] ?? []
            let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
            for key in keys {
                guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      let name = value["InterfaceName"] as? String else { continue }
                if let router = value["Router"] as? String { serviceRouters[name] = router }
                entries.append((key, name))
            }
        }
        let serviceIndex = Self.serviceOrderIndices(entries: entries, order: order)
        return counters
            .filter { $0.isUp && $0.kind.isPhysical && withIPv4.contains($0.name) }
            .map { counter in
                var router: String?
                if let store {
                    let key = "State:/Network/Interface/\(counter.name)/IPv4" as CFString
                    router = (SCDynamicStoreCopyValue(store, key) as? [String: Any])?["Router"] as? String
                }
                router = router ?? serviceRouters[counter.name]
                if router == nil, global?["PrimaryInterface"] as? String == counter.name {
                    router = global?["Router"] as? String
                }
                return Resolved(
                    candidate: UplinkCandidate(name: counter.name, hasRouter: router != nil, serviceOrderIndex: serviceIndex[counter.name]),
                    kind: counter.kind,
                    router: router
                )
            }
    }

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let holder = StoreHolder(continuation: continuation)
            let retained = Unmanaged.passRetained(holder)
            var context = SCDynamicStoreContext(
                version: 0,
                info: retained.toOpaque(),
                retain: nil,
                release: { Unmanaged<StoreHolder>.fromOpaque($0).release() },
                copyDescription: nil
            )
            let callback: SCDynamicStoreCallBack = { _, _, info in
                guard let info else { return }
                Unmanaged<StoreHolder>.fromOpaque(info).takeUnretainedValue().continuation.yield()
            }
            guard let store = SCDynamicStoreCreate(nil, "NetPulse" as CFString, callback, &context) else {
                retained.release()
                continuation.finish()
                return
            }
            SCDynamicStoreSetNotificationKeys(store, [Self.globalIPv4] as CFArray, Self.notificationPatterns as CFArray)
            holder.store = store
            SCDynamicStoreSetDispatchQueue(store, holder.queue)
            continuation.onTermination = { _ in
                if let store = holder.store { SCDynamicStoreSetDispatchQueue(store, nil) }
                holder.store = nil
            }
        }
    }

    private func observation(name: String, kind: InterfaceKind, router: String?) -> NetworkObservation {
        var ssid: String?
        if kind == .wifi {
            ssid = CWWiFiClient.shared().interface(withName: name)?.ssid()
        }
        var gatewayMAC: String?
        if let router, let table = GatewayARP.routeTable() {
            gatewayMAC = GatewayARP.mac(forRouter: router, in: table)
        }
        return NetworkObservation(
            interfaceName: name,
            kind: kind,
            ssid: ssid,
            gatewayMAC: gatewayMAC,
            interfaceMAC: NetworkIdentity.normalizedMAC(Self.hardwareAddress(of: name))
        )
    }

    private static func hardwareAddress(of bsdName: String) -> String? {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for interface in all where SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
            return SCNetworkInterfaceGetHardwareAddressString(interface) as String?
        }
        return nil
    }

    private static func systemConfigurationTypes() -> [String: String] {
        var map: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            map[name] = type
        }
        return map
    }

    private static func interfacesWithIPv4() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var names = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let addr = entry.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET {
                names.insert(String(cString: entry.pointee.ifa_name))
            }
            cursor = entry.pointee.ifa_next
        }
        return names
    }
}

private final class StoreHolder: @unchecked Sendable {
    let continuation: AsyncStream<Void>.Continuation
    let queue = DispatchQueue(label: "netpulse.network-changes")
    var store: SCDynamicStore?

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}
