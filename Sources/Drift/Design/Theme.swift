import AppKit
import SwiftUI

/// Drift's visual system.
///
/// One warm accent ("ember") on warm-neutral surfaces. The accent marks
/// *activity* — a running dot, the last minute, completion — and nothing else,
/// so the widget stays quiet until something actually matters.
enum Theme {
    // MARK: Color

    /// Ember: a muted, warm orange. Contrast ≥ 4.5:1 against both surfaces.
    static let accent = dynamic(light: NSColor(srgbRed: 0.69, green: 0.32, blue: 0.15, alpha: 1),
                                dark: NSColor(srgbRed: 0.95, green: 0.64, blue: 0.43, alpha: 1))

    /// Warm tint laid over the blur so the widget reads as a solid object,
    /// not a pane of glass.
    static let surface = dynamic(light: NSColor(srgbRed: 0.985, green: 0.975, blue: 0.96, alpha: 0.82),
                                 dark: NSColor(srgbRed: 0.11, green: 0.105, blue: 0.10, alpha: 0.80))

    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.10),
                                  dark: NSColor(white: 1, alpha: 0.10))

    static let primaryText = dynamic(light: NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 1),
                                     dark: NSColor(srgbRed: 0.96, green: 0.94, blue: 0.91, alpha: 1))

    static let secondaryText = dynamic(light: NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 0.58),
                                       dark: NSColor(srgbRed: 0.96, green: 0.94, blue: 0.91, alpha: 0.58))

    static let tertiaryText = dynamic(light: NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 0.38),
                                      dark: NSColor(srgbRed: 0.96, green: 0.94, blue: 0.91, alpha: 0.40))

    /// Hover/press wash for controls.
    static let control = dynamic(light: NSColor(white: 0, alpha: 0.055),
                                 dark: NSColor(white: 1, alpha: 0.08))

    static let controlHover = dynamic(light: NSColor(white: 0, alpha: 0.09),
                                      dark: NSColor(white: 1, alpha: 0.13))

    // MARK: Type

    /// Timer digits: SF Pro, medium, tabular figures so nothing shifts as
    /// seconds tick by.
    static func digits(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .default).monospacedDigit()
    }

    static let label = Font.system(size: 12, weight: .medium)
    static let small = Font.system(size: 11, weight: .medium)
    static let caption = Font.system(size: 10.5, weight: .regular)

    // MARK: Shape & motion

    static let cornerRadius: CGFloat = 12
    static let quick = Animation.spring(response: 0.26, dampingFraction: 0.92)
    static let gentle = Animation.easeInOut(duration: 0.45)

    // MARK: Helpers

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// AppKit blur behind SwiftUI content.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The shared "Drift surface": blur + warm tint + hairline, continuous corners.
struct DriftSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.cornerRadius
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    VisualEffectBackground()
                    Theme.surface
                }
                .opacity(opacity)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}

extension View {
    func driftSurface(cornerRadius: CGFloat = Theme.cornerRadius, opacity: Double = 1) -> some View {
        modifier(DriftSurface(cornerRadius: cornerRadius, opacity: opacity))
    }

    /// Rolling-digit transition on macOS 14+, a no-op before.
    @ViewBuilder
    func numericTransition() -> some View {
        if #available(macOS 14.0, *) {
            self.contentTransition(.numericText(countsDown: true))
        } else {
            self
        }
    }
}

/// Small, quiet button used throughout the widget and composer.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.small)
            .foregroundStyle(prominent ? Theme.accent : Theme.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Theme.controlHover : (hovering ? Theme.control : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Round icon button (play/pause etc.).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    var tint: Color = Theme.secondaryText
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(hovering ? Theme.primaryText : tint)
            .frame(width: size, height: size)
            .background(
                Circle().fill(configuration.isPressed ? Theme.controlHover : (hovering ? Theme.control : Color.clear))
            )
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// Renders a keyboard shortcut as small keycaps: ⌥ ⌘ T
struct KeyCaps: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.control))
    }
}
