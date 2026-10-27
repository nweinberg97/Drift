import AppKit
import Combine
import Foundation

/// User preferences, persisted to UserDefaults. Deliberately small.
@MainActor
final class AppSettings: ObservableObject {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum WidgetSize: String, CaseIterable, Identifiable {
        case compact, large
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var scale: CGFloat { self == .compact ? 1 : 1.3 }
    }

    /// How long a finished timer stays in view.
    enum FinishedRetention: String, CaseIterable, Identifiable {
        case untilDismissed, oneMinute, fiveMinutes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .untilDismissed: return "Until dismissed"
            case .oneMinute: return "For 1 minute"
            case .fiveMinutes: return "For 5 minutes"
            }
        }
        var interval: TimeInterval? {
            switch self {
            case .untilDismissed: return nil
            case .oneMinute: return 60
            case .fiveMinutes: return 300
            }
        }
    }

    /// How hard a finished timer tries to get your attention.
    enum CompletionAlert: String, CaseIterable, Identifiable {
        /// Chime repeats every few seconds until you dismiss it (up to 2 min).
        case untilDismissed
        /// One chime.
        case once
        var id: String { rawValue }
        var title: String {
            switch self {
            case .untilDismissed: return "Keep chiming until I dismiss it"
            case .once: return "Chime once"
            }
        }
    }

    /// A task you've timed before, offered under the launcher.
    struct RecentTask: Codable, Equatable, Identifiable {
        var name: String
        var seconds: TimeInterval
        var id: String { name.lowercased() }
    }

    static let defaultPresets: [TimeInterval] = [300, 600, 900, 1_200, 1_500, 1_800, 2_700, 3_600, 7_200]
    private static let oldDefaultPresets: [TimeInterval] = [300, 900, 1_500, 2_700, 3_600]

    private let defaults: UserDefaults

    // Timer
    @Published var defaultDuration: TimeInterval { didSet { set(defaultDuration, "defaultDuration") } }
    @Published var presets: [TimeInterval] { didSet { set(presets, "presets") } }
    @Published var finishedRetention: FinishedRetention { didSet { set(finishedRetention.rawValue, "finishedRetention") } }

    // Appearance
    @Published var appearance: Appearance { didSet { set(appearance.rawValue, "appearance"); applyAppearance() } }
    @Published var widgetSize: WidgetSize { didSet { set(widgetSize.rawValue, "widgetSize") } }
    @Published var widgetOpacity: Double { didSet { set(widgetOpacity, "widgetOpacity") } }

    // Sound
    @Published var completionSound: Bool { didSet { set(completionSound, "completionSound") } }
    @Published var completionAlert: CompletionAlert { didSet { set(completionAlert.rawValue, "completionAlert") } }
    @Published var startSound: Bool { didSet { set(startSound, "startSound") } }
    @Published var soundVolume: Double { didSet { set(soundVolume, "soundVolume2") } }
    @Published var notifications: Bool { didSet { set(notifications, "notifications") } }

    // Focus sound
    @Published var focusSoundEnabled: Bool { didSet { set(focusSoundEnabled, "focusSoundEnabled") } }
    @Published var soundscape: Soundscape { didSet { set(soundscape.rawValue, "soundscape") } }
    @Published var focusVolume: Double { didSet { set(focusVolume, "focusVolume") } }

    // Shortcuts
    @Published var shortcuts: [ShortcutAction: Shortcut] { didSet { saveShortcuts() } }

    // State
    @Published var widgetHidden: Bool { didSet { set(widgetHidden, "widgetHidden") } }
    /// Set once the user opens the composer with the keyboard; the shortcut
    /// hint disappears after that.
    @Published var hasLearnedShortcut: Bool { didSet { set(hasLearnedShortcut, "hasLearnedShortcut") } }
    /// Set once a timer has a task; the launcher's how-to line goes away.
    @Published var hasWrittenTask: Bool { didSet { set(hasWrittenTask, "hasWrittenTask") } }
    /// The first-launch guide has been shown.
    @Published var hasSeenWelcome: Bool { didSet { set(hasSeenWelcome, "hasSeenWelcome") } }
    @Published private(set) var recents: [RecentTask] { didSet { saveRecents() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultDuration = defaults.object(forKey: "defaultDuration") as? Double ?? 1_500.0
        let storedPresets = defaults.array(forKey: "presets") as? [Double]
        presets = (storedPresets == nil || storedPresets == Self.oldDefaultPresets) ? Self.defaultPresets : storedPresets!
        finishedRetention = FinishedRetention(rawValue: defaults.string(forKey: "finishedRetention") ?? "") ?? .untilDismissed
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        widgetSize = WidgetSize(rawValue: defaults.string(forKey: "widgetSize") ?? "") ?? .compact
        widgetOpacity = defaults.object(forKey: "widgetOpacity") as? Double ?? 1
        completionSound = defaults.object(forKey: "completionSound") as? Bool ?? true
        completionAlert = CompletionAlert(rawValue: defaults.string(forKey: "completionAlert") ?? "") ?? .untilDismissed
        startSound = defaults.object(forKey: "startSound") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume2") as? Double ?? 0.85
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
        focusSoundEnabled = defaults.object(forKey: "focusSoundEnabled") as? Bool ?? false
        soundscape = Soundscape(rawValue: defaults.string(forKey: "soundscape") ?? "") ?? .rain
        focusVolume = defaults.object(forKey: "focusVolume") as? Double ?? 0.35
        widgetHidden = defaults.object(forKey: "widgetHidden") as? Bool ?? false
        hasLearnedShortcut = defaults.object(forKey: "hasLearnedShortcut") as? Bool ?? false
        hasWrittenTask = defaults.object(forKey: "hasWrittenTask") as? Bool ?? false
        hasSeenWelcome = defaults.object(forKey: "hasSeenWelcome") as? Bool ?? false
        if let data = defaults.data(forKey: "recentTasks"),
           let stored = try? JSONDecoder().decode([RecentTask].self, from: data) {
            recents = stored
        } else {
            recents = []
        }

        var loaded = ShortcutAction.defaults
        if let data = defaults.data(forKey: "shortcuts"),
           let stored = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            for (key, value) in stored {
                if let action = ShortcutAction(rawValue: key) { loaded[action] = value }
            }
        }
        shortcuts = loaded
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Remembers a named timer so it's one click away next time.
    func remember(task name: String, seconds: TimeInterval) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let rounded = max(60, (seconds / 60).rounded() * 60)
        var list = recents.filter { $0.name.lowercased() != trimmed.lowercased() }
        list.insert(RecentTask(name: trimmed, seconds: rounded), at: 0)
        recents = Array(list.prefix(4))
        if !hasWrittenTask { hasWrittenTask = true }
    }

    func forgetRecents() {
        recents = []
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: "recentTasks")
        }
    }

    func resetShortcuts() {
        shortcuts = ShortcutAction.defaults
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func saveShortcuts() {
        let dict = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: "shortcuts")
        }
    }
}
