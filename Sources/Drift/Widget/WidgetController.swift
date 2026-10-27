import AppKit
import Combine
import SwiftUI

/// Owns the floating widget panel: where it lives, how it appears and hides,
/// and how it survives display changes.
@MainActor
final class WidgetController: NSObject, NSWindowDelegate {
    private let panel = FloatingPanel()
    private let store: TimerStore
    private let settings: AppSettings
    let ui = WidgetUIState()
    private var hosting: PanelHostingView<WidgetView>?
    private var cancellables = Set<AnyCancellable>()
    private var contentSize: CGSize = .zero
    private var isAnimatingVisibility = false

    var openComposer: () -> Void = {}
    var openVoice: () -> Void = {}
    var acknowledge: () -> Void = {}
    private var hideWork: DispatchWorkItem?

    private static let placementKey = "widgetPlacement"
    private static let inset: CGFloat = 14

    init(store: TimerStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        super.init()

        panel.delegate = self
        panel.setAccessibilityTitle("Drift")
        panel.onEscape = { [weak self] in self?.handleEscape() }
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onDragEnded = { [weak self] in self?.savePlacement() }

        let actions = WidgetActions(
            openComposer: { [weak self] in self?.openComposer() },
            openVoice: { [weak self] in self?.openVoice() },
            acknowledge: { [weak self] in self?.acknowledge() },
            hide: { [weak self] in self?.hide() },
            resize: { [weak self] size in self?.resize(to: size) },
            focusPanel: { [weak self] in self?.focus() },
            releaseFocus: { [weak self] in self?.releaseFocus() }
        )
        let view = WidgetView(store: store, settings: settings, ui: ui, actions: actions)
        let hosting = PanelHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting

        restorePlacement()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screensChanged() }
            .store(in: &cancellables)

        // Collapse back to one line once nothing needs the extra room.
        store.$timers
            .map(\.isEmpty)
            .removeDuplicates()
            .sink { [weak self] empty in if empty { self?.ui.expanded = false } }
            .store(in: &cancellables)

        // Dragging on the dial turns it; it mustn't move the widget.
        ui.$dialID
            .sink { [weak self] id in self?.panel.draggable = (id == nil) }
            .store(in: &cancellables)

        // Scrolling over the open dial turns it too.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel, self.ui.dialID != nil else { return event }
            self.scrollDial(event)
            return nil
        }
    }

    private var scrollMonitor: Any?
    private var scrollAccumulated: CGFloat = 0

    private func scrollDial(_ event: NSEvent) {
        let dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            scrollAccumulated += dy
            let steps = (scrollAccumulated / 8).rounded(.towardZero)
            guard steps != 0 else { return }
            scrollAccumulated -= steps * 8
            ui.setDial(ui.dialValue + Double(steps) * 60, store: store)
        } else if dy != 0 {
            ui.setDial(ui.dialValue + (dy > 0 ? 60 : -60), store: store)
        }
    }

    /// Opens a timer's label for editing, right in the widget.
    func beginRename(_ id: UUID) {
        guard let t = store.timer(id) else { return }
        show()
        ui.beginRename(t)
        focus()
    }

    /// Opens the dial for a timer.
    func openDial(_ id: UUID) {
        guard let t = store.timer(id) else { return }
        show()
        ui.openDial(t, now: Date())
        focus()
    }

    var isVisible: Bool { panel.isVisible && !settings.widgetHidden }

    // MARK: - Visibility

    func show() {
        settings.widgetHidden = false
        hideWork?.cancel()
        hideWork = nil
        ui.hideHint = false
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        ensureOnScreen()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animateAlpha(to: 1)
    }

    /// Hides the widget. With `hint`, it first says where it went and how to
    /// get it back, so it never just disappears.
    func hide(hint: Bool = true) {
        settings.widgetHidden = true
        ui.renamingID = nil
        ui.closeDial(commit: true, store: store)
        guard panel.isVisible else { return }
        hideWork?.cancel()
        let finish = DispatchWorkItem { [weak self] in
            guard let self, self.settings.widgetHidden else { return }
            self.animateAlpha(to: 0) { [weak self] in
                guard let self, self.settings.widgetHidden else { return }
                self.panel.orderOut(nil)
                self.ui.hideHint = false
                self.ui.expanded = false
            }
        }
        hideWork = finish
        if hint {
            ui.expanded = false
            ui.hideHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: finish)
        } else {
            ui.expanded = false
            finish.perform()
        }
    }

    func toggle() {
        isVisible ? hide(hint: false) : show()
    }

    /// A timer finished: make sure it's seen, with the finish controls open.
    func presentFinished(_ id: UUID, alerting: Bool) {
        store.makePrimary(id)
        show()
        ui.renamingID = nil
        ui.closeDial(commit: true, store: store)
        ui.expanded = true
        ui.alerting = alerting
    }

    /// Shows the widget expanded — "show my timers".
    func reveal() {
        show()
        if !store.timers.isEmpty { ui.expanded = true }
    }

    private func animateAlpha(to value: CGFloat, completion: (() -> Void)? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = value
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = value > 0 ? 0.18 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = value
        }, completionHandler: {
            Task { @MainActor in completion?() }
        })
    }

    // MARK: - Focus & keys

    func focus() {
        panel.makeKey()
    }

    /// Hands the keyboard back to whatever the user was working in. Ordering a
    /// non-activating panel out and straight back in makes the window server
    /// return key status to the frontmost app's window.
    private func releaseFocus() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        if !settings.widgetHidden { panel.orderFrontRegardless() }
    }

    private func handleEscape() {
        if ui.dialID != nil {
            ui.closeDial(commit: false, store: store)
        } else if ui.renamingID != nil {
            ui.renamingID = nil
        } else if ui.expanded {
            ui.expanded = false
        } else {
            hide()
            return
        }
        releaseFocus()
    }

    /// Keyboard control when the widget has focus:
    /// space pause/resume · +/− adjust 5 min · return expand · esc collapse/hide
    private func handleKey(_ event: NSEvent) -> Bool {
        if ui.dialID != nil {
            let step: TimeInterval = event.modifierFlags.contains(.shift) ? 300 : 60
            switch event.keyCode {
            case 126, 124: ui.setDial(ui.dialValue + step, store: store); return true   // ↑ →
            case 125, 123: ui.setDial(ui.dialValue - step, store: store); return true   // ↓ ←
            case 36, 76: ui.closeDial(commit: true, store: store); releaseFocus(); return true
            default: return false
            }
        }
        guard ui.renamingID == nil, let primary = store.primary else { return false }
        switch event.charactersIgnoringModifiers {
        case " ":
            if primary.isFinished { store.remove(primary.id) } else { store.toggle(primary.id) }
            return true
        case "+", "=":
            store.adjust(primary.id, by: 300)
            return true
        case "-", "_":
            store.adjust(primary.id, by: -300)
            return true
        case "\r":
            ui.expanded.toggle()
            return true
        default:
            return false
        }
    }

    // MARK: - Size & position

    /// Keeps the top-left corner pinned as the content grows or shrinks.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard rounded != contentSize else { return }
        contentSize = rounded
        let frame = panel.frame
        let top = frame.maxY
        var newFrame = NSRect(x: frame.minX, y: top - rounded.height, width: rounded.width, height: rounded.height)
        newFrame = clamped(newFrame)
        panel.setFrame(newFrame, display: true, animate: false)
    }

    private struct Placement: Codable {
        var screenID: UInt32?
        /// Top-left corner, in global screen coordinates.
        var x: CGFloat
        var top: CGFloat
    }

    private func savePlacement() {
        let frame = panel.frame
        let screen = panel.screen ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
        let placement = Placement(screenID: screen?.displayID, x: frame.minX, top: frame.maxY)
        if let data = try? JSONEncoder().encode(placement) {
            UserDefaults.standard.set(data, forKey: Self.placementKey)
        }
    }

    private func restorePlacement() {
        let size = panel.frame.size
        if let data = UserDefaults.standard.data(forKey: Self.placementKey),
           let placement = try? JSONDecoder().decode(Placement.self, from: data),
           NSScreen.screens.contains(where: { $0.displayID == placement.screenID }) {
            panel.setFrame(clamped(NSRect(x: placement.x, y: placement.top - size.height, width: size.width, height: size.height)), display: false)
        } else {
            moveToDefaultPosition()
        }
    }

    /// Top-left of the main display, just under the menu bar.
    func moveToDefaultPosition() {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.minX + Self.inset, y: visible.maxY - Self.inset * 0.7 - size.height))
        savePlacement()
    }

    /// If the display the widget lived on went away (or resolution changed),
    /// bring it back somewhere sensible.
    private func screensChanged() {
        let frame = panel.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 20, dy: 10)) }
        if onScreen {
            panel.setFrame(clamped(frame), display: true)
        } else {
            moveToDefaultPosition()
        }
    }

    private func ensureOnScreen() {
        let frame = panel.frame
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            moveToDefaultPosition()
        }
    }

    /// Keeps the frame within the visible area of whichever screen holds it.
    private func clamped(_ frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.minX + 20, y: frame.maxY - 10)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else {
            return frame
        }
        let v = screen.visibleFrame
        var f = frame
        if f.maxX > v.maxX { f.origin.x = v.maxX - f.width }
        if f.minX < v.minX { f.origin.x = v.minX }
        if f.maxY > v.maxY { f.origin.y = v.maxY - f.height }
        if f.minY < v.minY { f.origin.y = v.minY }
        return f
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Clicking away keeps what you changed.
        if ui.dialID != nil { ui.closeDial(commit: true, store: store) }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        savePlacement()
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
