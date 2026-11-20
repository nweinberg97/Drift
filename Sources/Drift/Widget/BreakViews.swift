import AppKit
import DriftCore
import SwiftUI

// MARK: - Look

extension BreakKind {
    /// One calm colour per kind, tuned for light and dark.
    var color: Color {
        switch self {
        case .move: return Theme.accent
        case .walk: return Self.dynamic(0x3F7D4E, 0x8CCB98)
        case .hydrate: return Self.dynamic(0x2F6F9E, 0x8EC3EA)
        case .snack: return Self.dynamic(0xC23A4B, 0xF2848F)
        case .breathe: return Self.dynamic(0x6A5BA8, 0xB7A9EC)
        }
    }

    var symbol: String {
        switch self {
        case .move: return "figure.flexibility"
        case .walk: return "figure.walk"
        case .hydrate: return "drop.fill"
        case .snack: return "fork.knife"
        case .breathe: return "wind"
        }
    }

    private static func dynamic(_ light: Int, _ dark: Int) -> Color {
        func ns(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

/// "Move", in its colour with its icon.
struct BreakChip: View {
    let kind: BreakKind
    var suffix: String?
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol).font(.system(size: 9.5 * scale, weight: .semibold))
            Text(suffix.map { "\(kind.title) \($0)" } ?? kind.title)
                .font(.system(size: 11 * scale, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 7 * scale)
        .frame(height: 20 * scale)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind.color.opacity(0.14)))
        .fixedSize()
    }
}

// MARK: - Block rows (planner and running session)

/// A break row's chip: click it to change the kind.
struct BreakKindMenu: View {
    let kind: BreakKind?
    let pick: (BreakKind?) -> Void
    let makeWork: () -> Void

    var body: some View {
        Menu {
            ForEach(BreakKind.allCases) { k in
                Button { pick(k) } label: { Label(k.title, systemImage: k.symbol) }
            }
            Button("Pick one for me") { pick(nil) }
            Divider()
            Button("Make it a work block", action: makeWork)
        } label: {
            if let kind {
                BreakChip(kind: kind, suffix: "break")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9.5, weight: .semibold))
                    Text("Break · picked for you").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.control))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointer(.pointingHand)
        .help("Change the kind of break")
    }
}

/// A time block's ⋯ menu: add a break or block after it, move it, delete it.
struct BlockRowMenu: View {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let isBreak: Bool
    let edit: (BlockEdit) -> Void

    var body: some View {
        Menu {
            Menu("Add a break after") {
                ForEach(BreakKind.allCases) { k in
                    Button { edit(.breakAfter(k)) } label: { Label(k.title, systemImage: k.symbol) }
                }
                Divider()
                Button("Pick one for me") { edit(.breakAfter(nil)) }
            }
            Button("Add a block after") { edit(.blockAfter) }
            Divider()
            Button("Move up") { edit(.moveUp) }.disabled(!canMoveUp)
            Button("Move down") { edit(.moveDown) }.disabled(!canMoveDown)
            if isBreak { Button("Make it a work block") { edit(.makeWork) } }
            Divider()
            Button("Delete") { edit(.delete) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointer(.pointingHand)
        .help("Add a break after this, move it, or delete it")
        .accessibilityLabel("More")
    }
}

/// "+ Add a break": at the end, or one between every pair of work blocks.
struct AddBreakMenu: View {
    var everyTitle = "Between every block"
    let atEnd: (BreakKind?) -> Void
    let between: (BreakKind?) -> Void

    var body: some View {
        Menu {
            ForEach(BreakKind.allCases) { k in
                Button { atEnd(k) } label: { Label(k.title, systemImage: k.symbol) }
            }
            Button("Pick one for me") { atEnd(nil) }
            Divider()
            Menu(everyTitle) {
                ForEach(BreakKind.allCases) { k in
                    Button { between(k) } label: { Label(k.title, systemImage: k.symbol) }
                }
                Divider()
                Button("Pick for me each time") { between(nil) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("Add a break")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointer(.pointingHand)
        .help("A guided break at the end, or one between every block")
    }
}

// MARK: - The break card

/// Shown in place of the timer row while a guided break runs: what to do,
/// how long is left, and Done / Swap / Skip.
struct BreakCard: View {
    let timer: DriftTimer
    let now: BreakNow
    @ObservedObject var store: TimerStore
    let scale: CGFloat

    private var s: CGFloat { min(scale, 1.15) }

    var body: some View {
        let left = timer.remaining(at: store.now)
        let progress = timer.duration > 0 ? max(0, min(1, 1 - left / timer.duration)) : 0
        let kind = now.kind
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 10 * s, weight: .semibold))
                    .frame(width: 20 * s, height: 20 * s)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind.color.opacity(0.16)))
                Text("\(kind.title) break".uppercased())
                    .font(.system(size: 10.5 * s, weight: .bold))
                    .tracking(0.4)
                Spacer(minLength: 6)
                Text(TimeFormatter.clock(left))
                    .font(.system(size: 20 * s, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
            }
            .foregroundStyle(kind.color)

            Text(now.activity.name)
                .font(.system(size: 17 * s, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .padding(.top, 7)
                .id(now.activity.name)
                .transition(.opacity)
            Text(now.activity.detail)
                .font(.system(size: 12 * s))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            if !now.activity.steps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(now.activity.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("\(i + 1)")
                                .font(.system(size: 9.5 * s, weight: .bold))
                                .foregroundStyle(kind.color)
                                .frame(width: 15 * s, height: 15 * s)
                                .background(Circle().fill(kind.color.opacity(0.16)))
                            Text(step)
                                .font(.system(size: 12 * s))
                                .foregroundStyle(Theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(kind.color).frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 3)
            .padding(.top, 11)

            HStack(spacing: 6) {
                Button { withAnimation(Theme.quick) { store.endBreak(timer.id) } } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(BreakButtonStyle(scale: scale, tint: kind.color))
                .help("End the break and get back to it")
                Button { withAnimation(Theme.quick) { store.swapBreak(timer.id) } } label: {
                    Label("Swap", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(CardButtonStyle(scale: scale))
                .help("Something else to do")
                Button { withAnimation(Theme.quick) { store.endBreak(timer.id) } } label: { Text("Skip") }
                    .buttonStyle(CardButtonStyle(scale: scale))
                    .help("Skip this break")
            }
            .padding(.top, 11)
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 12 * scale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.title) break: \(now.activity.name). \(TimeFormatter.spoken(left)) left.")
    }
}

/// The wide Done button, in the break's colour.
struct BreakButtonStyle: ButtonStyle {
    /// White on the deep light-mode colours; near-black on the pale dark-mode ones.
    static let ink = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.11, green: 0.09, blue: 0.08, alpha: 1) : .white
    })

    let scale: CGFloat
    let tint: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5 * min(scale, 1.15), weight: .semibold))
            .foregroundStyle(Self.ink)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30 * min(scale, 1.15))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint))
            .brightness(hovering ? 0.05 : 0)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Under a running focus round: "Next · [Move] 5 min break".
struct NextBreakLine: View {
    let kind: BreakKind
    let duration: TimeInterval
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text("Next").font(.system(size: 11 * scale)).foregroundStyle(Theme.secondaryText)
            BreakChip(kind: kind, scale: min(scale, 1.15))
            Text("\(TimeFormatter.compact(duration)) break").font(.system(size: 11 * scale)).foregroundStyle(Theme.secondaryText)
        }
        .padding(.leading, 33 * scale)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings › Breaks

struct BreakSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var open: BreakKind? = .move
    @State private var newName = ""

    var body: some View {
        Section {
            Toggle(isOn: $settings.guidedBreaks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guided breaks")
                    Text("Breaks tell you what to do: move, walk, hydrate, snack or breathe.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.guidedBreaks {
                Picker("Long Pomodoro break", selection: $settings.breakLongKind) {
                    ForEach(BreakKind.allCases) { Text($0.title).tag($0) }
                }
                Picker("Order", selection: $settings.breakMix) {
                    Text("Rotate").tag(false)
                    Text("Mix").tag(true)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Short breaks use the ticked kinds. Open a kind to choose its activities or add your own.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    ForEach(BreakKind.allCases) { kind in kindRow(kind) }
                }
            }
        } header: {
            Text("Breaks")
        }
    }

    @ViewBuilder
    private func kindRow(_ kind: BreakKind) -> some View {
        let list = settings.activities(kind)
        let on = list.filter(\.enabled).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Toggle("", isOn: Binding(get: { settings.breakShortKinds.contains(kind) },
                                         set: { _ in settings.toggleShortKind(kind) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help("Use \(kind.title) for short breaks")
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kind.color)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind.color.opacity(0.15)))
                Text(kind.title).fontWeight(.medium)
                Spacer()
                Button {
                    withAnimation(Theme.quick) { open = open == kind ? nil : kind }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(on) of \(list.count)").monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open == kind ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 5)
            if open == kind {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(list) { a in
                        HStack {
                            Toggle(a.name, isOn: Binding(get: { a.enabled }, set: { settings.setActivity(a.id, enabled: $0) }))
                                .toggleStyle(.checkbox)
                            if a.custom {
                                Spacer()
                                Button { settings.removeActivity(a.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help("Remove")
                            }
                        }
                    }
                    HStack {
                        TextField("", text: $newName, prompt: Text("Add your own…"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { add(kind) }
                        Button("Add") { add(kind) }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 2)
                }
                .padding(.leading, 31)
                .padding(.bottom, 8)
            }
        }
    }

    private func add(_ kind: BreakKind) {
        settings.addActivity(kind, name: newName)
        newName = ""
    }
}
