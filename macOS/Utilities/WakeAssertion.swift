import Foundation

/// Keeps the Mac from falling asleep while it is holding something the phone
/// depends on — a location session, or the remote control server.
///
/// This uses the supported activity API, which prevents *idle* sleep. It
/// deliberately does not keep the display awake, and it cannot override sleep
/// the user asks for, a closing lid, or a flat battery.
@MainActor
final class WakeAssertion {
    private var token: NSObjectProtocol?
    private var reasons: Set<String> = []

    var isActive: Bool { token != nil }

    var activeReasons: [String] { reasons.sorted() }

    /// Holds the Mac awake for as long as this reason is present.
    func acquire(reason: String) {
        reasons.insert(reason)
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Dissappear Companion: \(reason)")
    }

    func release(reason: String) {
        reasons.remove(reason)
        guard reasons.isEmpty, let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    func releaseAll() {
        reasons.removeAll()
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    enum Reason {
        static let locationSession = "holding a device location session"
        static let remoteControl = "serving remote control to an iPhone"
    }
}
