import CoreLocation
import os

enum LocationPermission {
    static let askedKey = "didAskLocation"

    @MainActor private static var holder: Holder?

    @MainActor
    static var isUndetermined: Bool { CLLocationManager().authorizationStatus == .notDetermined }

    @MainActor
    static func start(
        defaults: UserDefaults = .standard,
        onAuthorized: @escaping @MainActor () -> Void = {},
        onDetermined: @escaping @MainActor () -> Void = {}
    ) {
        guard holder == nil else { return }
        let holder = Holder(defaults: defaults, onAuthorized: onAuthorized, onDetermined: onDetermined)
        Self.holder = holder
        guard !defaults.bool(forKey: askedKey) else { return }
        if holder.manager.authorizationStatus == .notDetermined {
            holder.manager.requestWhenInUseAuthorization()
        } else {
            defaults.set(true, forKey: askedKey)
        }
    }

    @MainActor
    private final class Holder: NSObject, CLLocationManagerDelegate {
        let manager = CLLocationManager()
        private let defaults: UserDefaults
        private let onAuthorized: @MainActor () -> Void
        private let onDetermined: @MainActor () -> Void
        // authorizedWhenInUse (4) is marked unavailable on macOS but can still be reported
        private static let authorizedWhenInUseRaw: Int32 = 4
        private var wasAuthorized = false
        private let log = Logger(subsystem: "NetPulse", category: "location")

        init(defaults: UserDefaults, onAuthorized: @escaping @MainActor () -> Void, onDetermined: @escaping @MainActor () -> Void) {
            self.defaults = defaults
            self.onAuthorized = onAuthorized
            self.onDetermined = onDetermined
            super.init()
            manager.delegate = self
        }

        nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let status = manager.authorizationStatus
            Task { @MainActor in self.changed(to: status) }
        }

        private func changed(to status: CLAuthorizationStatus) {
            if status != .notDetermined {
                defaults.set(true, forKey: LocationPermission.askedKey)
                onDetermined()
            }
            let authorized = status == .authorizedAlways || status.rawValue == Self.authorizedWhenInUseRaw
            log.info("location authorization changed: \(status.rawValue) authorized=\(authorized)")
            if authorized && !wasAuthorized { onAuthorized() }
            wasAuthorized = authorized
        }
    }
}
