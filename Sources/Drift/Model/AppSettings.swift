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
    @Published var startSound: Bool { didSet { set(startSound, "startSound") } }
    @Published var soundVolume: Double { didSet { set(soundVolume, "soundVolume") } }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultDuration = defaults.object(forKey: "defaultDuration") as? Double ?? 25 * 60
        presets = defaults.array(forKey: "presets") as? [Double] ?? [5 * 60, 15 * 60, 25 * 60, 45 * 60, 60 * 60]
        finishedRetention = FinishedRetention(rawValue: defaults.string(forKey: "finishedRetention") ?? "") ?? .untilDismissed
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        widgetSize = WidgetSize(rawValue: defaults.string(forKey: "widgetSize") ?? "") ?? .compact
        widgetOpacity = defaults.object(forKey: "widgetOpacity") as? Double ?? 1
        completionSound = defaults.object(forKey: "completionSound") as? Bool ?? true
        startSound = defaults.object(forKey: "startSound") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.6
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
        focusSoundEnabled = defaults.object(forKey: "focusSoundEnabled") as? Bool ?? false
        soundscape = Soundscape(rawValue: defaults.string(forKey: "soundscape") ?? "") ?? .brownNoise
        focusVolume = defaults.object(forKey: "focusVolume") as? Double ?? 0.35
        widgetHidden = defaults.object(forKey: "widgetHidden") as? Bool ?? false
        hasLearnedShortcut = defaults.object(forKey: "hasLearnedShortcut") as? Bool ?? false

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
