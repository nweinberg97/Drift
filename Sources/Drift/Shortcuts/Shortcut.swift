import AppKit
import Carbon.HIToolbox

/// The handful of global commands Drift exposes.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case newTimer
    case toggleWidget
    case voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTimer: return "New timer"
        case .toggleWidget: return "Show / hide widget"
        case .voice: return "Voice command"
        }
    }

    /// Two-key defaults, easy to hit one-handed:
    ///   ⌥Space  new timer (Spotlight-like)
    ///   ⌥V      voice
    ///   ⌥T      show / hide widget
    /// They avoid ⌘-combos that apps use (⌘⇧T reopens tabs in every browser).
    /// ⌥-letter normally types a rarely used symbol (√, †), and ⌥Space a
    /// non-breaking space, so claiming them costs almost nothing.
    static let defaults: [ShortcutAction: Shortcut] = [
        .newTimer: Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.option], key: "Space"),
        .voice: Shortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.option], key: "V"),
        .toggleWidget: Shortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.option], key: "T"),
    ]

    var hotKeyID: UInt32 {
        switch self {
        case .newTimer: return 1
        case .toggleWidget: return 2
        case .voice: return 3
        }
    }
}

/// A key + modifier combination.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifierFlags: UInt
    /// Human-readable key, captured when recorded ("T", "Space", "F5").
    var key: String

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.intersection([.command, .option, .control, .shift]).rawValue
        self.key = key
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// "⌃⌥⌘T" — Apple's canonical modifier order.
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return key.count > 1 ? s + " " + key : s + key
    }

    /// For NSMenuItem.keyEquivalent display.
    var menuKeyEquivalent: String {
        if key == "Space" { return " " }
        return key.count == 1 ? key.lowercased() : ""
    }

    /// Builds a shortcut from a key-down event, or nil if it has no
    /// ⌘/⌥/⌃ modifier (a global shortcut must not swallow plain typing).
    static func from(event: NSEvent) -> Shortcut? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.intersection([.command, .option, .control]).isEmpty else { return nil }
        return Shortcut(keyCode: event.keyCode, modifiers: mods, key: keyName(for: event))
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            let chars = event.charactersIgnoringModifiers?.uppercased() ?? "?"
            return chars.isEmpty ? "?" : chars
        }
    }
}
