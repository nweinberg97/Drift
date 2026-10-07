import AppKit
import Combine
import DriftCore

/// Drift's menu-bar presence.
///
/// The icon is a tiny progress ring for the featured timer. When the widget
/// is hidden, the remaining time appears next to it — so hiding the widget
/// never means losing track.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        var newTimer: () -> Void
        var voice: () -> Void
        var toggleWidget: () -> Void
        var openSettings: () -> Void
        var rename: (UUID) -> Void
        var edit: (UUID) -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: TimerStore
    private let settings: AppSettings
    private let actions: Actions
    private var cancellables = Set<AnyCancellable>()
    private var timerItems: [UUID: NSMenuItem] = [:]
    private var lastIconKey = ""
    private var lastTitle = ""

    init(store: TimerStore, settings: AppSettings, actions: Actions) {
        self.store = store
        self.settings = settings
        self.actions = actions
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel("Drift")

        store.$now
            .combineLatest(store.$timers, settings.$widgetHidden)
            .sink { [weak self] _ in
                // Publishers fire before the value lands; read on the next turn.
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: - Status button

    private func refresh() {
        let now = Date()
        let primary = store.primary

        var fraction: Double = 0
        var mode = "idle"
        if let p = primary {
            fraction = 1 - p.progress(at: now)
            mode = p.isFinished ? "done" : (p.isRunning ? "run" : "pause")
        }
        let quantized = (fraction * 48).rounded() / 48
        let key = "\(mode)-\(quantized)"
        if key != lastIconKey {
            lastIconKey = key
            item.button?.image = MenuBarIcon.image(remainingFraction: quantized, mode: mode)
        }

        var title = ""
        if settings.widgetHidden, let p = primary {
            title = p.isFinished ? "Done" : TimeFormatter.clock(p.remaining(at: now))
        }
        if title != lastTitle {
            lastTitle = title
            item.button?.attributedTitle = NSAttributedString(
                string: title.isEmpty ? "" : " " + title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]
            )
        }

        if let p = primary {
            let name = p.displayName ?? "Timer"
            item.button?.setAccessibilityValue(p.isFinished ? "\(name) finished" : "\(name), \(TimeFormatter.spoken(p.remaining(at: now).rounded(.up))) left")
        } else {
            item.button?.setAccessibilityValue("No timers")
        }

        updateLiveTimerItems(now: now)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        timerItems = [:]
        let now = Date()

        let ordered = [store.primary].compactMap { $0 } + store.others
        if ordered.isEmpty {
            let empty = NSMenuItem(title: "No timers running", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for timer in ordered {
                let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                row.attributedTitle = timerTitle(timer, now: now)
                row.submenu = submenu(for: timer)
                row.image = statusImage(for: timer)
                timerItems[timer.id] = row
                menu.addItem(row)
            }
            if store.timers.contains(where: \.isFinished) {
                menu.addItem(action("Clear Finished", #selector(clearFinished)))
            }
        }

        menu.addItem(.separator())

        let newItem = action("New Timer…", #selector(newTimer))
        applyShortcut(.newTimer, to: newItem)
        menu.addItem(newItem)

        for seconds in settings.presets.prefix(4) {
            let start = action("Start \(TimeFormatter.compact(seconds))", #selector(startPreset(_:)))
            start.representedObject = seconds
            start.indentationLevel = 1
            menu.addItem(start)
        }
        let pomodoro = action("Start Pomodoro  25 / 5", #selector(startPomodoro))
        pomodoro.indentationLevel = 1
        menu.addItem(pomodoro)

        let voiceItem = action("Voice Command…", #selector(voice))
        applyShortcut(.voice, to: voiceItem)
        menu.addItem(voiceItem)

        menu.addItem(.separator())

        let toggle = action(settings.widgetHidden ? "Show Widget" : "Hide Widget", #selector(toggleWidget))
        applyShortcut(.toggleWidget, to: toggle)
        menu.addItem(toggle)

        menu.addItem(.separator())

        let focus = action("Focus Sound", #selector(toggleFocusSound))
        focus.state = settings.focusSoundEnabled ? .on : .off
        menu.addItem(focus)

        let scapes = NSMenuItem(title: "Soundscape", action: nil, keyEquivalent: "")
        let scapeMenu = NSMenu()
        for scape in Soundscape.allCases {
            let s = action(scape.title, #selector(selectSoundscape(_:)))
            s.representedObject = scape.rawValue
            s.state = settings.soundscape == scape ? .on : .off
            scapeMenu.addItem(s)
        }
        scapeMenu.addItem(.separator())
        scapeMenu.addItem(volumeItem())
        scapes.submenu = scapeMenu
        scapes.indentationLevel = 1
        menu.addItem(scapes)

        menu.addItem(.separator())
        let settingsItem = action("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        let quit = action("Quit Drift", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Shows the global shortcut beside the item (display only — the hotkey
    /// itself is registered system-wide).
    private func applyShortcut(_ action: ShortcutAction, to item: NSMenuItem) {
        guard let s = settings.shortcuts[action], !s.menuKeyEquivalent.isEmpty else { return }
        item.keyEquivalent = s.menuKeyEquivalent
        item.keyEquivalentModifierMask = s.modifiers
    }

    private func timerTitle(_ timer: DriftTimer, now: Date) -> NSAttributedString {
        let name = timer.displayName ?? TimeFormatter.compact(timer.duration) + " timer"
        let time = timer.isFinished ? "Done" : TimeFormatter.clock(timer.remaining(at: now))
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 200, options: [:])]
        let s = NSMutableAttributedString(string: "\(name)\t", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .paragraphStyle: paragraph,
        ])
        s.append(NSAttributedString(string: time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: timer.isPaused ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))
        return s
    }

    private func statusImage(for timer: DriftTimer) -> NSImage? {
        let name = timer.isFinished ? "checkmark.circle" : (timer.isRunning ? "circle.fill" : "pause.circle")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        return image?.withSymbolConfiguration(config)
    }

    private func submenu(for timer: DriftTimer) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ selector: Selector, enabled: Bool = true) {
            let i = action(title, selector)
            i.representedObject = timer.id
            i.isEnabled = enabled
            menu.addItem(i)
        }
        if timer.isFinished {
            add("Add 5 Minutes", #selector(addFive(_:)))
            add("Restart", #selector(toggleTimer(_:)))
            menu.addItem(.separator())
            add("Dismiss", #selector(removeTimer(_:)))
        } else {
            add(timer.isRunning ? "Pause" : "Resume", #selector(toggleTimer(_:)))
            add("Add 5 Minutes", #selector(addFive(_:)))
            add("Remove 5 Minutes", #selector(removeFive(_:)), enabled: timer.remaining(at: Date()) > 300)
            add("Edit Time…", #selector(editTimer(_:)))
            add("Rename…", #selector(renameTimer(_:)))
            add("Duplicate", #selector(duplicateTimer(_:)))
            if store.primary?.id != timer.id {
                add("Show in Widget", #selector(featureTimer(_:)))
            }
            menu.addItem(.separator())
            add("Cancel Timer", #selector(removeTimer(_:)))
        }
        return menu
    }

    private func volumeItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        let low = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil) ?? NSImage())
        low.frame = NSRect(x: 18, y: 6, width: 14, height: 16)
        low.contentTintColor = .secondaryLabelColor
        let slider = NSSlider(value: settings.focusVolume, minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 38, y: 4, width: 148, height: 20)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel("Focus sound volume")
        container.addSubview(low)
        container.addSubview(slider)
        let item = NSMenuItem()
        item.view = container
        return item
    }

    /// Keeps the countdowns in an open menu ticking.
    private func updateLiveTimerItems(now: Date) {
        guard !timerItems.isEmpty else { return }
        for timer in store.timers {
            timerItems[timer.id]?.attributedTitle = timerTitle(timer, now: now)
        }
    }

    // MARK: - Actions

    @objc private func newTimer() { actions.newTimer() }
    @objc private func voice() { actions.voice() }
    @objc private func toggleWidget() { actions.toggleWidget() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func clearFinished() { store.removeAllFinished() }
    @objc private func toggleFocusSound() { settings.focusSoundEnabled.toggle() }

    @objc private func startPreset(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        store.create(seconds: seconds)
    }

    @objc private func startPomodoro() {
        store.startPomodoro(focus: CommandParser.defaultPomodoro.focus, rest: CommandParser.defaultPomodoro.rest)
    }

    @objc private func selectSoundscape(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scape = Soundscape(rawValue: raw) else { return }
        settings.soundscape = scape
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        settings.focusVolume = sender.doubleValue
    }

    private func id(_ sender: NSMenuItem) -> UUID? { sender.representedObject as? UUID }

    @objc private func toggleTimer(_ sender: NSMenuItem) { if let id = id(sender) { store.toggle(id) } }
    @objc private func addFive(_ sender: NSMenuItem) { if let id = id(sender) { store.adjust(id, by: 300) } }
    @objc private func removeFive(_ sender: NSMenuItem) { if let id = id(sender) { store.adjust(id, by: -300) } }
    @objc private func duplicateTimer(_ sender: NSMenuItem) { if let id = id(sender) { store.duplicate(id) } }
    @objc private func removeTimer(_ sender: NSMenuItem) { if let id = id(sender) { store.remove(id) } }
    @objc private func featureTimer(_ sender: NSMenuItem) { if let id = id(sender) { store.makePrimary(id) } }
    @objc private func renameTimer(_ sender: NSMenuItem) { if let id = id(sender) { actions.rename(id) } }
    @objc private func editTimer(_ sender: NSMenuItem) { if let id = id(sender) { actions.edit(id) } }
}

/// Template icon: a ring that empties clockwise as time runs out.
enum MenuBarIcon {
    static func image(remainingFraction: Double, mode: String) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 2, dy: 2)
            let center = NSPoint(x: inset.midX, y: inset.midY)
            let radius = inset.width / 2

            let ring = NSBezierPath(ovalIn: inset)
            ring.lineWidth = 1.6
            NSColor.black.withAlphaComponent(mode == "idle" ? 1 : 0.35).setStroke()
            ring.stroke()

            switch mode {
            case "done":
                NSColor.black.setFill()
                NSBezierPath(ovalIn: inset.insetBy(dx: 2.2, dy: 2.2)).fill()
            case "run", "pause":
                guard remainingFraction > 0 else { break }
                let path = NSBezierPath()
                path.move(to: center)
                path.appendArc(withCenter: center, radius: radius,
                               startAngle: 90, endAngle: 90 - 360 * remainingFraction, clockwise: true)
                path.close()
                NSColor.black.withAlphaComponent(mode == "run" ? 1 : 0.55).setFill()
                path.fill()
            default:
                break
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
