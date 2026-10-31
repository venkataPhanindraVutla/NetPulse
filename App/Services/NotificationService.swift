import Foundation
import NetPulseCore
import os
import UserNotifications

enum NotificationAuthorization: Sendable, Equatable {
    case unknown, notDetermined, denied, authorized
}

actor NotificationService {
    private let log = Logger(subsystem: "NetPulse", category: "notifications")

    func status() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let current = Self.map(await center.notificationSettings().authorizationStatus)
        switch current {
        case .authorized: return true
        case .denied: return false
        case .notDetermined, .unknown:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.info("notification authorization requested: granted=\(granted)")
                return granted
            } catch {
                log.error("notification authorization failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
    }

    func post(_ a: CapAlert, networkName: String, resets: Date) async {
        let status = await status()
        guard status == .authorized else {
            log.info("cap alert not posted, notifications status=\(String(describing: status), privacy: .public)")
            return
        }
        let period = a.period == .monthly ? "monthly" : "daily"
        let content = UNMutableNotificationContent()
        content.title = a.threshold >= 100 ? "\(networkName): \(period) cap reached" : "\(networkName): \(a.threshold)% of \(period) cap"
        content.body = "\(ByteFormatter.bytes(a.used)) of \(ByteFormatter.bytes(a.limit)) used · resets \(Self.resetText(resets))"
        content.sound = .default
        let id = "cap-\(a.networkID)-\(a.period.rawValue)-\(a.threshold)-\(Int(resets.timeIntervalSince1970))"
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            log.error("cap alert failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func resetText(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = .autoupdatingCurrent
        format.timeZone = .autoupdatingCurrent
        format.setLocalizedDateFormatFromTemplate("MMMd")
        return format.string(from: date)
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }
}

final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
