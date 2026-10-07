import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats above normal windows,
/// follows the user across Spaces, and appears over full-screen apps.
///
/// Non-activating is the key property: clicking the widget never pulls focus
/// away from the app you're working in. The panel only becomes key when a
/// text field inside it genuinely needs the keyboard.
class FloatingPanel: NSPanel {
    /// Return true to consume a key press while the panel is key.
    var keyHandler: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?
    var draggable = true
    var onDragEnded: (() -> Void)?

    private var mouseDownEvent: NSEvent?

    init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 200, height: 60)) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        isMovable = true
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// Click-vs-drag discrimination: a click goes to SwiftUI as usual; once
    /// the pointer moves a few points with the button down, the window server
    /// takes over and moves the panel natively.
    override func sendEvent(_ event: NSEvent) {
        guard draggable else { return super.sendEvent(event) }
        switch event.type {
        case .leftMouseDown:
            mouseDownEvent = event
            super.sendEvent(event)
        case .leftMouseDragged:
            if let down = mouseDownEvent {
                let a = down.locationInWindow, b = event.locationInWindow
                if hypot(a.x - b.x, a.y - b.y) > 3 {
                    mouseDownEvent = nil
                    performDrag(with: down)
                    onDragEnded?()
                    return
                }
            }
            super.sendEvent(event)
        case .leftMouseUp:
            mouseDownEvent = nil
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}

/// Hosts SwiftUI content in a panel whose frame tracks the content's ideal
/// size, keeping a chosen corner fixed so the widget grows *down* from its
/// top-left corner instead of jumping around.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reports a view's size up to AppKit.
struct SizeReporter: ViewModifier {
    let onChange: (CGSize) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onChange(proxy.size) }
                    .onChange(of: proxy.size) { onChange($0) }
            }
        )
    }
}

extension View {
    func reportSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        modifier(SizeReporter(onChange: onChange))
    }
}
