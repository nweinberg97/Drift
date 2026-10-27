import Foundation

/// The app's name and version, read from the bundle so a rename is one change
/// (CFBundleDisplayName in the Info.plist; see scripts/rename.py).
enum AppInfo {
    static var name: String {
        let info = Bundle.main.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty { return display }
        if let bundle = info?["CFBundleName"] as? String, !bundle.isEmpty { return bundle }
        return "Drift"
    }

    /// Help pages on the website. Opening a link uses the browser, so the app
    /// itself still needs no network access.
    static let supportURL = URL(string: "https://nweinberg97.github.io/Drift/support.html")!
    static let guideURL = URL(string: "https://nweinberg97.github.io/Drift/guide.html")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
