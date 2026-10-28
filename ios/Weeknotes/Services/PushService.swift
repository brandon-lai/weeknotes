import UIKit
import UserNotifications

/// Notification permission and taps. Weekly reminders are local notifications
/// (`LocalReminders`), so the app doesn't register with APNs.
final class PushService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushService()
    var onOpenCompose: (() -> Void)?

    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { onOpenCompose?() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {}
