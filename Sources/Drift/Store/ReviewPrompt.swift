import Foundation
import StoreKit

/// Asks for an App Store rating after the 3rd, 15th and 50th finished timer:
/// late enough that the person knows the app, and never more than that.
/// macOS decides whether the prompt actually appears (at most three times a
/// year), and it never shows in the developer build.
enum ReviewPrompt {
    private static let key = "finishedTimerCount"
    private static let moments: Set<Int> = [3, 15, 50]

    @MainActor
    static func timerFinished() {
        #if APPSTORE
        let count = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(count, forKey: key)
        guard moments.contains(count) else { return }
        // A beat after the Time's up card, not on top of the chime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            SKStoreReviewController.requestReview()
        }
        #endif
    }
}
