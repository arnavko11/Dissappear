import Foundation
import UserNotifications

/// Tells the user, as a notification, what will end a spoof held away from
/// Wi-Fi. On cellular a lost connection cannot be reopened until Wi-Fi is
/// back, so the two things that kill it — swiping the app away, and Low
/// Power Mode suspending it — are worth an interruption.
@MainActor
final class SpoofWarnings: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var lowPowerObserver: NSObjectProtocol?

    /// Asked for at the first on-device spoof, when the reason is obvious.
    func requestPermission() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Low Power Mode is watched only while something is being held.
    func watchLowPower(_ isHolding: @escaping @MainActor () -> Bool) {
        guard lowPowerObserver == nil else { return }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, isHolding(), ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
                self.post(id: "lowpower",
                          title: "Low Power Mode can end your spoof",
                          body: "It can suspend Dissappear, which drops the connection — and on cellular it can't be reopened until you're on Wi-Fi. Turn Low Power Mode off while spoofing.")
            }
        }
    }

    func cellularStarted() {
        var body = "Keep Dissappear running: don't swipe it away in the app switcher. On cellular the connection can't be reopened until you're back on Wi-Fi."
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            body += " Low Power Mode is on — turn it off, or it may suspend the app."
        } else {
            body += " Keep Low Power Mode off."
        }
        post(id: "cellular", title: "On cellular — your spoof depends on this app", body: body)
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Same identifier replaces rather than stacks.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // Show it even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
