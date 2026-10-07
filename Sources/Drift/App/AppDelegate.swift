import AppKit
import Carbon
import Combine
import DriftCore

@main
enum DriftMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // A menu-bar utility: no Dock icon, no app switcher entry.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

/// Wires the pieces together. Each component is small and owns one job:
/// TimerStore (state), WidgetController (floating timer), ComposerController
/// (launcher), StatusItemController (menu bar), and the services.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, TimerStoreDelegate {
    private var settings: AppSettings!
    private var store: TimerStore!
    private var runner: CommandRunner!
    private var widget: WidgetController!
    private var composer: ComposerController!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private let voice = VoiceController()
    private let notifications = NotificationService()
    private let chimes = Chimes()
    private let focusSound = FocusSoundPlayer()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        settings.applyAppearance()

        store = TimerStore(settings: settings)
        store.delegate = self

        runner = CommandRunner(store: store, settings: settings)
        widget = WidgetController(store: store, settings: settings)
        composer = ComposerController(runner: runner, settings: settings, voice: voice)
        settingsWindow = SettingsWindowController(settings: settings)

        runner.showWidget = { [weak self] in self?.widget.show() }
        runner.revealTimers = { [weak self] in self?.widget.reveal() }
        runner.hideWidget = { [weak self] in self?.widget.hide() }
        widget.openComposer = { [weak self] in self?.composer.show() }
        notifications.onActivate = { [weak self] in self?.widget.reveal() }
        settingsWindow.onRecordingChanged = { [weak self] recording in
            // Release global hotkeys while recording so the recorder can see them.
            if recording { HotKeyCenter.shared.unregisterAll() } else { self?.registerHotKeys() }
        }
        settingsWindow.resetWidgetPosition = { [weak self] in
            self?.widget.moveToDefaultPosition()
            self?.widget.show()
        }

        statusItem = StatusItemController(store: store, settings: settings, actions: .init(
            newTimer: { [weak self] in self?.composer.show() },
            voice: { [weak self] in self?.composer.show(listening: true) },
            toggleWidget: { [weak self] in self?.widget.toggle() },
            openSettings: { [weak self] in self?.settingsWindow.show() },
            rename: { [weak self] id in self?.beginEditing(id, rename: true) },
            edit: { [weak self] id in self?.beginEditing(id, rename: false) }
        ))

        registerHotKeys()
        settings.$shortcuts
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKeys() } }
            .store(in: &cancellables)

        Publishers.CombineLatest3(settings.$focusSoundEnabled, settings.$soundscape, settings.$focusVolume)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.syncFocusSound() } }
            .store(in: &cancellables)
        settings.$notifications
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.syncNotifications() } }
            .store(in: &cancellables)

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        if !settings.widgetHidden { widget.show() }
        syncNotifications()
        syncFocusSound()
    }

    /// Opening Drift again (Finder, Spotlight, Launchpad) brings the widget back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        widget.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        for action in ShortcutAction.allCases {
            guard let shortcut = settings.shortcuts[action] else { continue }
            let ok = center.register(id: action.hotKeyID, shortcut: shortcut) { [weak self] in
                self?.perform(action)
            }
            if !ok { NSLog("Drift: \(shortcut.display) is already in use by another app.") }
        }
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .newTimer:
            settings.hasLearnedShortcut = true
            composer.toggle()
        case .toggleWidget:
            widget.toggle()
        case .voice:
            composer.show(listening: true)
        }
    }

    private func beginEditing(_ id: UUID, rename: Bool) {
        guard let timer = store.timer(id) else { return }
        store.makePrimary(id)
        widget.show()
        widget.ui.expanded = true
        widget.ui.draft = rename ? (timer.name ?? "") : TimeFormatter.compact(timer.remaining(at: Date()))
        if rename { widget.ui.renamingID = id } else { widget.ui.editingID = id }
        widget.focus()
    }

    // MARK: - TimerStoreDelegate

    func timerStore(_ store: TimerStore, didStart timer: DriftTimer) {
        if settings.startSound { chimes.playStart(volume: settings.soundVolume) }
        if settings.notifications { notifications.requestAuthorizationIfNeeded() }
    }

    func timerStore(_ store: TimerStore, didFinish timer: DriftTimer, late: Bool) {
        guard !late else { return }
        if settings.completionSound { chimes.playComplete(volume: settings.soundVolume) }
    }

    func timerStoreScheduleDidChange(_ store: TimerStore) {
        syncNotifications()
        syncFocusSound()
    }

    private func syncNotifications() {
        notifications.sync(timers: store.timers, enabled: settings.notifications)
    }

    /// Focus sound plays while any timer runs — except during Pomodoro breaks.
    private func syncFocusSound() {
        let focusing = store.timers.contains { $0.isRunning && $0.pomodoro?.phase != .rest }
        focusSound.update(
            shouldPlay: settings.focusSoundEnabled && focusing,
            soundscape: settings.soundscape,
            volume: settings.focusVolume
        )
    }

    // MARK: - drift:// URLs

    /// Automation entry point for Shortcuts, Siri ("Hey Siri, focus for
    /// 25 minutes" via a Shortcut), Raycast, Alfred, or Terminal:
    ///
    ///   drift://start?duration=25m&name=Writing
    ///   drift://run?q=45%20minutes%20writing
    ///   drift://new · drift://voice · drift://show · drift://hide · drift://toggle
    ///
    /// Any web page can try to open a custom URL, so links are limited to
    /// harmless actions: they can start, show, pause, resume or extend timers,
    /// but never cancel or shorten one.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let components = URLComponents(string: string),
              components.scheme?.lowercased() == "drift"
        else { return }

        let host = (components.host ?? "").lowercased()
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let pathArgument = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding ?? ""

        switch host {
        case "new", "composer":
            composer.show()
        case "voice", "listen":
            composer.show(listening: true)
        case "show":
            widget.reveal()
        case "hide":
            widget.hide()
        case "toggle":
            widget.toggle()
        case "start":
            let text = [query["duration"] ?? query["d"] ?? pathArgument, query["name"] ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if let parsed = DurationParser.parse(text) {
                runner.run(.start(seconds: parsed.seconds, name: query["name"].flatMap { $0.isEmpty ? nil : $0 } ?? parsed.label))
            } else {
                runner.run("")
            }
        case "run", "command":
            let text = query["q"] ?? query["text"] ?? pathArgument
            guard let command = CommandParser.parse(text) else { composer.show(); return }
            switch command {
            case .cancel:
                return
            case let .adjust(delta, _) where delta < 0:
                return
            default:
                runner.run(command)
            }
        default:
            composer.show()
        }
    }
}
