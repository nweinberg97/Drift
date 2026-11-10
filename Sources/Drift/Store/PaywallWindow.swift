import AppKit
import SwiftUI

/// The one place Drift asks for money: the free trial first, then three
/// plans with every feature in each. Opens when someone without access starts
/// a timer, and from the menu bar and Settings.
@MainActor
final class PaywallWindowController {
    private var window: NSWindow?
    private let purchases: Purchases

    init(purchases: Purchases = .shared) {
        self.purchases = purchases
    }

    func show() {
        if window == nil {
            let view = PaywallScreen(purchases: purchases, close: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Unlock \(AppInfo.name)"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        Task { await purchases.loadProducts() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

/// Live wrapper: reads Purchases and closes itself once unlocked.
struct PaywallScreen: View {
    @ObservedObject var purchases: Purchases
    let close: () -> Void
    @State private var selected = Purchases.ID.yearly

    var body: some View {
        PaywallView(
            ended: purchases.access == .trialEnded,
            trialAvailable: purchases.trialAvailable,
            plans: purchases.plans,
            selected: $selected,
            busy: purchases.busy,
            message: purchases.message,
            startTrial: { Task { await purchases.startTrial() } },
            buy: { id in Task { await purchases.buy(id) } },
            restore: { Task { await purchases.restore() } },
            close: close
        )
        .onChange(of: purchases.isUnlocked) { unlocked in
            if unlocked && purchases.access != .checking { close() }
        }
    }
}

/// Pure view, so snapshots can render it without the App Store.
struct PaywallView: View {
    let ended: Bool
    let trialAvailable: Bool
    let plans: [Purchases.Plan]
    @Binding var selected: String
    let busy: String?
    let message: String?
    let startTrial: () -> Void
    let buy: (String) -> Void
    let restore: () -> Void
    let close: () -> Void

    private var selectedPlan: Purchases.Plan? { plans.first { $0.id == selected } ?? plans.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ended ? "Your free week is over" : "Unlock \(AppInfo.name)")
                        .font(.system(size: 21, weight: .semibold))
                    Text("Every feature in every plan. No account, no tracking.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 9) {
                Feature(symbol: "timer", text: "A calm floating timer that never steals focus")
                Feature(symbol: "square.stack", text: "Sessions with time blocks that hand off on their own")
                Feature(symbol: "calendar", text: "Plans for today and routines that repeat")
                Feature(symbol: "waveform", text: "Pomodoro, focus sounds and voice")
            }
            .padding(.bottom, 18)

            if trialAvailable {
                Button(action: startTrial) {
                    HStack {
                        if busy == Purchases.ID.trial { ProgressView().controlSize(.small) }
                        Text("Try everything free for \(Purchases.trialDays) days")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                .disabled(busy != nil)
                Text("No card needed. Nothing renews.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                HStack {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    Text("or unlock now").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                .padding(.vertical, 14)
            }

            VStack(spacing: 8) {
                ForEach(plans) { plan in
                    PlanRow(plan: plan, selected: plan.id == selectedPlan?.id) { selected = plan.id }
                }
            }

            if let plan = selectedPlan {
                Button { buy(plan.id) } label: {
                    HStack {
                        if busy == plan.id { ProgressView().controlSize(.small) }
                        Text(plan.id == Purchases.ID.lifetime ? "Buy Lifetime" : "Subscribe \(plan.title)")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(trialAvailable ? Color.primary.opacity(0.75) : Theme.accent)
                .controlSize(.large)
                .disabled(busy != nil)
                .padding(.top, 12)
            }

            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            Text("Subscriptions renew automatically until cancelled; cancel any time in your App Store account settings at least a day before renewal. Lifetime is a one-time purchase.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack(spacing: 14) {
                Button("Restore Purchases", action: restore).disabled(busy != nil)
                Link("Terms of Use", destination: AppInfo.termsURL)
                Link("Privacy", destination: AppInfo.privacyURL)
                Spacer()
                Button("Not now", action: close).keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .padding(.top, 12)
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Feature: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent.opacity(0.12)))
                .accessibilityHidden(true)
            Text(text).font(.system(size: 13))
        }
    }
}

private struct PlanRow: View {
    let plan: Purchases.Plan
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plan.title).font(.system(size: 13, weight: .semibold))
                        if let badge = plan.badge {
                            Text(badge.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accent.opacity(0.14)))
                        }
                    }
                    Text(plan.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(plan.price).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.08) : Theme.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
