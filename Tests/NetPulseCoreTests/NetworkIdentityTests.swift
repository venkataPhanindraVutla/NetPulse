import Darwin
import Foundation
import Testing
@testable import NetPulseCore

struct NetworkIdentityTests {
    @Test func wifiWithSSID() {
        #expect(NetworkIdentity.key(for: .init(interfaceName: "en0", kind: .wifi, ssid: "Home", gatewayMAC: "aa:bb:cc:00:11:22", interfaceMAC: nil))
            == NetworkKey(fingerprint: "wifi:ssid:Home", kind: .wifi, suggestedName: "Home"))
    }

    @Test func wifiWithoutSSIDUsesGateway() {
        #expect(NetworkIdentity.key(for: .init(interfaceName: "en0", kind: .wifi, ssid: nil, gatewayMAC: "AA:BB:CC:0:11:22", interfaceMAC: nil))
            == NetworkKey(fingerprint: "wifi:gw:aa:bb:cc:00:11:22", kind: .wifi, suggestedName: "Wi-Fi network"))
    }

    @Test func wifiWithNeither() {
        #expect(NetworkIdentity.key(for: .init(interfaceName: "en0", kind: .wifi, ssid: nil, gatewayMAC: nil, interfaceMAC: "aa:bb:cc:00:11:22")) == nil)
    }

    @Test func ethernetUsesInterfaceMAC() {
        #expect(NetworkIdentity.key(for: .init(interfaceName: "en5", kind: .ethernet, ssid: nil, gatewayMAC: nil, interfaceMAC: "AA:BB:CC:00:11:22"))
            == NetworkKey(fingerprint: "eth:aa:bb:cc:00:11:22", kind: .ethernet, suggestedName: "Ethernet (en5)"))
    }

    @Test func ethernetWithoutInterfaceMAC() {
        #expect(NetworkIdentity.key(for: .init(interfaceName: "en5", kind: .ethernet, ssid: nil, gatewayMAC: "aa:bb:cc:00:11:22", interfaceMAC: nil)) == nil)
    }

    @Test func ssidChangeIsNewNetwork() {
        let a = NetworkIdentity.key(for: .init(interfaceName: "en0", kind: .wifi, ssid: "Home", gatewayMAC: "aa:bb:cc:00:11:22", interfaceMAC: nil))
        let b = NetworkIdentity.key(for: .init(interfaceName: "en0", kind: .wifi, ssid: "Cafe", gatewayMAC: "aa:bb:cc:00:11:22", interfaceMAC: nil))
        #expect(a != nil && b != nil && a != b)
    }

    @Test func nonPhysicalKindsHaveNoKey() {
        #expect(NetworkIdentity.key(for: .init(interfaceName: "utun3", kind: .virtual, ssid: nil, gatewayMAC: nil, interfaceMAC: "aa:bb:cc:00:11:22")) == nil)
    }

    @Test func malformedMACIsRejected() {
        #expect(NetworkIdentity.normalizedMAC("aa:bb:cc") == nil)
        #expect(NetworkIdentity.normalizedMAC("zz:bb:cc:00:11:22") == nil)
        #expect(NetworkIdentity.normalizedMAC(nil) == nil)
    }

    @Test func keyRoundTripsThroughCodable() throws {
        let key = NetworkKey(fingerprint: "wifi:ssid:Home", kind: .wifi, suggestedName: "Home")
        let data = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(NetworkKey.self, from: data) == key)
    }
}

struct GatewayARPTests {
    private func entry(ip: [UInt8], mac: [UInt8], extra: Int = 0) -> [UInt8] {
        var msg = [UInt8](repeating: 0, count: MemoryLayout<rt_msghdr>.size)
        let inarp: [UInt8] = [16, UInt8(AF_INET), 0, 0] + ip + [0, 0, 0, 0, 0, 0, 0, 0]
        var dl: [UInt8] = [14, UInt8(AF_LINK), 1, 0, 0, 0, 6, 0]
        dl += mac
        dl += [UInt8](repeating: 0, count: extra)
        msg += inarp + dl
        let length = UInt16(msg.count)
        withUnsafeBytes(of: length) { msg.replaceSubrange(0..<2, with: $0) }
        return msg
    }

    @Test func findsMatchingRouterAmongEntries() {
        let buffer = entry(ip: [192, 168, 1, 20], mac: [1, 2, 3, 4, 5, 6])
            + entry(ip: [192, 168, 1, 1], mac: [0xaa, 0xbb, 0xcc, 0x00, 0x11, 0x2f], extra: 2)
        #expect(GatewayARP.mac(forRouter: "192.168.1.1", in: buffer) == "aa:bb:cc:00:11:2f")
    }

    @Test func skipsMalformedMessageAndKeepsWalking() {
        var bad = [UInt8](repeating: 0, count: 8)
        bad[0] = 8
        let buffer = bad + entry(ip: [10, 0, 0, 1], mac: [1, 2, 3, 4, 5, 6])
        #expect(GatewayARP.mac(forRouter: "10.0.0.1", in: buffer) == "01:02:03:04:05:06")
    }

    @Test func missingRouterReturnsNil() {
        let buffer = entry(ip: [192, 168, 1, 20], mac: [1, 2, 3, 4, 5, 6])
        #expect(GatewayARP.mac(forRouter: "192.168.1.1", in: buffer) == nil)
        #expect(GatewayARP.mac(forRouter: "not-an-ip", in: buffer) == nil)
        #expect(GatewayARP.mac(forRouter: "192.168.1.1", in: []) == nil)
    }
}

struct SystemNetworkDetectorTests {
    @Test func primaryIsNilOrNamed() {
        if let o = SystemNetworkDetector().primary() {
            #expect(!o.interfaceName.isEmpty)
            #expect(o.kind.isPhysical)
        }
    }

    @Test func activePhysicalAreAllPhysical() {
        for o in SystemNetworkDetector().activePhysical() {
            #expect(o.kind.isPhysical && !o.interfaceName.isEmpty)
        }
    }
}

struct NetworkChangesTests {
    @Test func streamStartsAndTerminatesCleanly() async {
        let task = Task { for await _ in SystemNetworkDetector().changes() {} }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await task.value
    }
}

struct UplinkChoiceTests {
    typealias C = SystemNetworkDetector.UplinkCandidate

    @Test func changeNotificationsCoverLateDHCPOnAnyInterface() {
        #expect(SystemNetworkDetector.notificationPatterns.contains("State:/Network/Interface/.*/IPv4"))
        #expect(SystemNetworkDetector.notificationPatterns.contains("State:/Network/Interface/.*/AirPort"))
    }

    @Test func routedBeatsUnrouted() {
        #expect(SystemNetworkDetector.chooseUplink([C(name: "en0", hasRouter: false, serviceOrderIndex: 0), C(name: "en5", hasRouter: true, serviceOrderIndex: 1)]) == "en5")
    }

    @Test func lowerServiceOrderWins() {
        #expect(SystemNetworkDetector.chooseUplink([C(name: "en0", hasRouter: true, serviceOrderIndex: 2), C(name: "en5", hasRouter: true, serviceOrderIndex: 1)]) == "en5")
    }

    @Test func noRouterIsNil() {
        #expect(SystemNetworkDetector.chooseUplink([C(name: "en0", hasRouter: false, serviceOrderIndex: 0)]) == nil)
    }

    @Test func singleRoutedCandidate() {
        #expect(SystemNetworkDetector.chooseUplink([C(name: "en0", hasRouter: true, serviceOrderIndex: nil)]) == "en0")
    }

    @Test func serviceIDParsing() {
        #expect(SystemNetworkDetector.serviceID(fromStateKey: "State:/Network/Service/ABC-123/IPv4") == "ABC-123")
        #expect(SystemNetworkDetector.serviceID(fromStateKey: "State:/Network/Service") == nil)
        #expect(SystemNetworkDetector.serviceID(fromStateKey: "garbage") == nil)
        #expect(SystemNetworkDetector.serviceID(fromStateKey: "State:/Network/Service//IPv4") == nil)
    }

    @Test func serviceOrderDrivesChoiceThroughLivePath() {
        let entries: [(key: String, interface: String)] = [
            ("State:/Network/Service/WIFI/IPv4", "en0"),
            ("State:/Network/Service/ETH/IPv4", "en5"),
        ]
        let indices = SystemNetworkDetector.serviceOrderIndices(entries: entries, order: ["ETH", "WIFI"])
        #expect(indices == ["en5": 0, "en0": 1])
        let candidates = ["en0", "en5"].map { C(name: $0, hasRouter: true, serviceOrderIndex: indices[$0]) }
        #expect(SystemNetworkDetector.chooseUplink(candidates) == "en5")
    }
}
