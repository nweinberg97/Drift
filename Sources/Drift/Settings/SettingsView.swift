import AppKit
import DriftCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    var onRecordingChanged: (Bool) -> Void = { _ in }
    var resetWidgetPosition: () -> Void = {}

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let view = SettingsView(
                settings: settings,
                onRecordingChanged: { [weak self] in self?.onRecordingChanged($0) },
                resetWidgetPosition: { [weak self] in self?.resetWidgetPosition() }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Drift Settings"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 620))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onRecordingChanged: (Bool) -> Void
    let resetWidgetPosition: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var presetsText = ""
    @State private var defaultText = ""

    var body: some View {
        Form {
            Section("Timer") {
                LabeledContent("Default length") {
                    DurationField(text: $defaultText, placeholder: "25m") { seconds in
                        settings.defaultDuration = seconds
                    }
                }
                LabeledContent("Quick starts") {
                    TextField("5m 15m 25m 45m 1h", text: $presetsText)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(savePresets)
                        .frame(maxWidth: 200)
                }
                Picker("Keep finished timers", selection: $settings.finishedRetention) {
                    ForEach(AppSettings.FinishedRetention.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Widget size", selection: $settings.widgetSize) {
                    ForEach(AppSettings.WidgetSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Widget opacity") {
                    Slider(value: $settings.widgetOpacity, in: 0.55...1)
                        .frame(maxWidth: 200)
                }
                LabeledContent("Widget position") {
                    Button("Move to Top Left", action: resetWidgetPosition)
                }
            }

            Section("Sound") {
                Toggle("Completion chime", isOn: $settings.completionSound)
                Toggle("Soft tick when a timer starts", isOn: $settings.startSound)
                LabeledContent("Chime volume") {
                    Slider(value: $settings.soundVolume, in: 0...1)
                        .frame(maxWidth: 200)
                }
                Toggle("Notification when a timer finishes", isOn: $settings.notifications)
            }

            Section {
                Toggle("Play while a timer runs", isOn: $settings.focusSoundEnabled)
                Picker("Soundscape", selection: $settings.soundscape) {
                    ForEach(Soundscape.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Volume") {
                    Slider(value: $settings.focusVolume, in: 0...1)
                        .frame(maxWidth: 200)
                }
            } header: {
                Text("Focus Sound")
            } footer: {
                Text("Generated live on your Mac. Pauses during Pomodoro breaks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(
                            shortcut: Binding(
                                get: { settings.shortcuts[action] },
                                set: { settings.shortcuts[action] = $0 }
                            ),
                            onRecordingChanged: onRecordingChanged
                        )
                    }
                }
                Button("Restore Defaults") { settings.resetShortcuts() }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Work from any app, including full-screen ones. Drift also responds to drift:// links — handy for Shortcuts, Siri and Raycast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open Drift at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("General")
            } footer: {
                Text("Drift works entirely on your Mac: no account, no network, no analytics. Voice is processed on-device and never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 520)
        .onAppear {
            presetsText = settings.presets.map(TimeFormatter.compact).joined(separator: " ")
            defaultText = TimeFormatter.compact(settings.defaultDuration)
        }
    }

    private func savePresets() {
        let parsed = presetsText
            .split(separator: " ")
            .compactMap { DurationParser.parse(String($0))?.seconds }
        if !parsed.isEmpty { settings.presets = Array(parsed.prefix(5)) }
        presetsText = settings.presets.map(TimeFormatter.compact).joined(separator: " ")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Couldn't change this — move Drift to your Applications folder and try again."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// A text field that accepts any Drift duration ("25", "1h 30m") on Return.
private struct DurationField: View {
    @Binding var text: String
    let placeholder: String
    let commit: (TimeInterval) -> Void
    @State private var invalid = false

    var body: some View {
        TextField(placeholder, text: $text)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 120)
            .foregroundStyle(invalid ? Color.red : Color.primary)
            .onSubmit {
                if let d = DurationParser.parse(text) {
                    commit(d.seconds)
                    text = TimeFormatter.compact(d.seconds)
                    invalid = false
                } else {
                    invalid = true
                }
            }
    }
}

/// Click, then press a key combination. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    let onRecordingChanged: (Bool) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : (shortcut?.display ?? "None"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 96)
        }
        .help(recording ? "Press Esc to cancel, Delete to clear" : "Click to record a new shortcut")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stop()
            case 51, 117: // Delete, Forward Delete
                shortcut = nil
                stop()
            default:
                if let s = Shortcut.from(event: event) {
                    shortcut = s
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            onRecordingChanged(false)
        }
    }
}
