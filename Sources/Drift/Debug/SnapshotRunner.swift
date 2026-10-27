import AppKit
import DriftCore
import SwiftUI

/// Renders the widget and launcher in a set of representative states to PNG
/// files, then quits. Used by CI so UI changes can be reviewed as images
/// without a Mac at hand:
///
///   DRIFT_SNAPSHOT_DIR=out .build/debug/Drift
///
/// Rendering uses AppKit's cached display, which skips the behind-window blur,
/// so each image is drawn over a neutral "desktop" backdrop instead.
@MainActor
final class SnapshotRunner: NSObject, NSApplicationDelegate {
    private let directory: URL
    private let settings: AppSettings
    private let store: TimerStore
    private let voice = VoiceController()
    private var window: NSWindow?

    init(directory: URL) {
        self.directory = directory
        let suite = UserDefaults(suiteName: "drift.snapshots") ?? .standard
        suite.removePersistentDomain(forName: "drift.snapshots")
        settings = AppSettings(defaults: suite)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drift-snapshots-\(UUID().uuidString).json")
        store = TimerStore(settings: settings, fileURL: file)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            await self.renderAll()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Scenarios

    private struct Scenario {
        var name: String
        var timers: [DriftTimer]
        var primary: UUID?
        var expanded = false
        var hideHint = false
        var alerting = false
        var renaming = false
        var dial: TimeInterval?
        var focusSound = false
        var dark = false
    }

    private func running(_ name: String?, total: TimeInterval, left: TimeInterval, pomodoro: PomodoroCycle? = nil) -> DriftTimer {
        let now = Date()
        var t = DriftTimer(name: name, duration: total, pomodoro: pomodoro)
        t.state = .running(endDate: now.addingTimeInterval(left))
        t.startedAt = now.addingTimeInterval(left - total)
        return t
    }

    private func paused(_ name: String?, total: TimeInterval, left: TimeInterval) -> DriftTimer {
        var t = DriftTimer(name: name, duration: total)
        t.state = .paused(remaining: left)
        t.startedAt = Date().addingTimeInterval(-60)
        return t
    }

    private func finished(_ name: String?, total: TimeInterval) -> DriftTimer {
        var t = DriftTimer(name: name, duration: total)
        t.state = .finished(at: Date())
        return t
    }

    private func scenarios() -> [Scenario] {
        let writing = running("Writing", total: 2_700, left: 1_453.4)
        let unnamed = running(nil, total: 1_500, left: 1_213.4)
        let laundry = running("Laundry", total: 3_600, left: 2_462.4)
        let tea = paused("Tea", total: 300, left: 192)
        var focus = PomodoroCycle()
        focus.round = 2
        let pomo = running(nil, total: 1_500, left: 931.4, pomodoro: focus)
        var rest = PomodoroCycle()
        rest.round = 2
        rest.phase = .rest
        let pomoBreak = running(nil, total: 300, left: 244.4, pomodoro: rest)
        let done = finished("Email", total: 1_500)

        return [
            Scenario(name: "01-idle", timers: []),
            Scenario(name: "02-running-collapsed", timers: [writing], primary: writing.id),
            Scenario(name: "03-several-collapsed", timers: [writing, laundry, tea], primary: writing.id),
            Scenario(name: "04-several-expanded", timers: [writing, laundry, tea], primary: writing.id, expanded: true),
            Scenario(name: "05-unnamed-expanded", timers: [unnamed], primary: unnamed.id, expanded: true, focusSound: true),
            Scenario(name: "06-renaming", timers: [unnamed], primary: unnamed.id, expanded: true, renaming: true),
            Scenario(name: "07-pomodoro-focus-expanded", timers: [pomo], primary: pomo.id, expanded: true),
            Scenario(name: "08-pomodoro-break-collapsed", timers: [pomoBreak], primary: pomoBreak.id),
            Scenario(name: "09-finished-alerting", timers: [done, laundry], primary: done.id, expanded: true, alerting: true),
            Scenario(name: "10-hide-hint", timers: [writing], primary: writing.id, hideHint: true),
            Scenario(name: "11-dark-expanded", timers: [writing, laundry, tea], primary: writing.id, expanded: true, focusSound: true, dark: true),
            Scenario(name: "12-dark-collapsed", timers: [writing, laundry], primary: writing.id, dark: true),
            Scenario(name: "13-unnamed-collapsed", timers: [unnamed], primary: unnamed.id),
            Scenario(name: "14-dial", timers: [writing], primary: writing.id, dial: 1_920),
            Scenario(name: "15-dial-dark-hours", timers: [laundry], primary: laundry.id, dial: 5_400, dark: true),
        ]
    }

    // MARK: - Rendering

    private func renderAll() async {
        for s in scenarios() {
            store.replaceAll(s.timers, primary: s.primary)
            settings.focusSoundEnabled = s.focusSound
            let ui = WidgetUIState()
            ui.expanded = s.expanded
            ui.hideHint = s.hideHint
            ui.alerting = s.alerting
            if s.renaming, let id = s.primary {
                ui.renamingID = id
                ui.draft = "Email"
            }
            if let value = s.dial, let id = s.primary {
                ui.dialID = id
                ui.dialValue = value
            }
            let actions = WidgetActions(
                openComposer: {}, openVoice: {}, acknowledge: {}, hide: {},
                resize: { _ in }, focusPanel: {}, releaseFocus: {}
            )
            let view = WidgetView(store: store, settings: settings, ui: ui, actions: actions)
            await render(view, name: s.name, dark: s.dark)
        }

        // Launcher states.
        let runner = CommandRunner(store: store, settings: settings)
        let launcher: [(String, String, Bool, Bool)] = [
            ("20-launcher-first-run", "", false, false),
            ("21-launcher-task-only", "Write intro", false, false),
            ("22-launcher-task-and-time", "Write intro 45m", false, false),
            ("23-launcher-number", "25", false, false),
            ("24-launcher-recents", "", true, false),
            ("25-launcher-dark-words", "Reading for an hour and a half", true, true),
        ]
        for (name, text, returning, dark) in launcher {
            settings.forgetRecents()
            settings.hasWrittenTask = false
            if returning {
                settings.remember(task: "Email", seconds: 1_500)
                settings.remember(task: "Write intro", seconds: 2_700)
            }
            let model = ComposerModel()
            model.text = text
            let view = ComposerView(
                model: model, settings: settings, voice: voice,
                preview: { runner.preview($0) },
                plan: { runner.plan($0) },
                submit: {}, startPreset: { _ in }, startRecent: { _ in }, startPomodoro: {},
                toggleVoice: {}, close: {}, resize: { _ in }
            )
            await render(view, name: name, dark: dark)
        }
    }

    private func render<V: View>(_ content: V, name: String, dark: Bool) async {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let backdrop = dark ? Color(red: 0.13, green: 0.12, blue: 0.11) : Color(red: 0.86, green: 0.85, blue: 0.83)
        let framed = content
            .padding(28)
            .background(backdrop)
            .environment(\.colorScheme, dark ? .dark : .light)

        let hosting = NSHostingView(rootView: framed)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window

        // Let SwiftUI lay out, settle animations and resize.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let finalSize = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: finalSize)
        window.setContentSize(finalSize)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
            print("snapshot \(name) \(Int(finalSize.width))x\(Int(finalSize.height))")
        }
        window.orderOut(nil)
    }
}
