import AppKit
import SwiftUI

/// The first-launch guide. A menu-bar app has no Dock icon and no window, so
/// this is how someone new (and App Review) learns where everything is.
/// Reopen it any time from the menu bar: Getting Started.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    /// "Try it now": opens the launcher.
    var tryIt: () -> Void = {}

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let view = WelcomeView(
                settings: settings,
                tryIt: { [weak self] in
                    self?.window?.close()
                    self?.tryIt()
                },
                close: { [weak self] in self?.window?.close() }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to \(AppInfo.name)"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        settings.hasSeenWelcome = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    @ObservedObject var settings: AppSettings
    let tryIt: () -> Void
    let close: () -> Void

    private var newTimerKeys: String { settings.shortcuts[.newTimer]?.display ?? "⌥ Space" }
    private var toggleKeys: String { settings.shortcuts[.toggleWidget]?.display ?? "⌥ T" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to \(AppInfo.name)")
                        .font(.system(size: 22, weight: .semibold))
                    Text("A quiet timer that stays with you. Here's everything, in four lines.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 16) {
                Step(symbol: "keyboard", title: "Press \(newTimerKeys) from any app",
                     detail: "Write what you're working on and for how long, like “Write intro 25m”, then press Return.",
                     keys: newTimerKeys)
                Step(symbol: "rectangle.topthird.inset.filled", title: "Your timer sits in the top-left corner",
                     detail: "Click its name to rename it and its time to turn the dial. \(toggleKeys) hides it; the time moves to the menu bar.",
                     keys: nil)
                Step(symbol: "calendar", title: "Plan your day",
                     detail: "Type when instead of how long: “Deep work 9–10:30 weekdays”. When it's time, \(AppInfo.name) asks, then starts it.",
                     keys: nil)
                Step(symbol: "mic", title: "Or just say it",
                     detail: "Press \(newTimerKeys) twice and talk. Speech is recognised on this Mac and never stored.",
                     keys: nil)
            }

            Text("Everything else is in the menu bar icon, including Settings and this guide (Getting Started).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 20)

            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Try it now", action: tryIt)
                    .keyboardShortcut(.defaultAction)
                    .tint(Theme.accent)
            }
            .controlSize(.large)
            .padding(.top, 20)
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Step: View {
    let symbol: String
    let title: String
    let detail: String
    let keys: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
