import UserNotifications

private struct NotificationsDisabled: LocalizedError {
    var errorDescription: String? { "Powiadomienia są wyłączone" }
}

/// The notification center is touched only through here, so an unconfigured launch never reaches it.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = Notifier()

    private static func center() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        return center
    }

    static func isAuthorized() async -> Bool {
        let status = await center().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// Prompts only while the owner has not been asked yet.
    static func requestAuthorizationIfNeeded() async throws {
        let center = center()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert])
        }
    }

    static func post(_ title: String, _ body: String) async throws {
        guard await isAuthorized() else { throw NotificationsDisabled() }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try await center().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Without this a notification posted while the app is active (its menu open) is not shown.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
