import AppKit
import DriftCore
import UserNotifications

/// Completion notifications, scheduled *ahead of time* with the system.
///
/// Scheduling at start (rather than posting when we notice a timer ended)
/// means the banner arrives on time even if Drift is suspended, killed, or the
/// Mac just woke — macOS delivers it for us.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    var onActivate: (() -> Void)?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when the binary isn't inside an
        // .app bundle (e.g. `swift run`). Notifications simply turn off there.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private var authorizationRequested = false

    override init() {
        super.init()
        center?.delegate = self
    }

    /// Asked lazily, the first time a timer starts — not at launch.
    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested, let center else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Replaces all pending notifications with one per running timer.
    func sync(timers: [DriftTimer], enabled: Bool, now: Date = Date()) {
        guard let center else { return }
        center.removeAllPendingNotificationRequests()
        guard enabled else { return }

        for timer in timers where timer.isRunning {
            let remaining = timer.remaining(at: now)
            guard remaining > 0.5 else { continue }

            let content = UNMutableNotificationContent()
            let copy = Self.copy(for: timer)
            content.title = copy.title
            content.body = copy.body
            content.sound = nil // Drift plays its own, gentler chime.
            content.threadIdentifier = "drift.timers"

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
            let request = UNNotificationRequest(identifier: timer.id.uuidString, content: content, trigger: trigger)
            center.add(request)
        }
    }

    static func copy(for timer: DriftTimer) -> (title: String, body: String) {
        if let cycle = timer.pomodoro {
            switch cycle.phase {
            case .focus:
                return ("Focus complete", "\(TimeFormatter.spoken(cycle.focus)) done. Break for \(TimeFormatter.spoken(cycle.rest)).")
            case .rest:
                return ("Break's over", "Back to focus for \(TimeFormatter.spoken(cycle.focus)).")
            }
        }
        let title = timer.name.map { "\($0) finished" } ?? "Timer finished"
        return (title, "\(TimeFormatter.spoken(timer.duration)) complete.")
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in self.onActivate?() }
        completionHandler()
    }
}
