import AppKit
import Foundation
import StoreKit

/// What the person has paid for, read from the App Store with StoreKit 2.
///
/// Drift is a free download with every feature in every plan:
///   - a free 7-day trial (a $0 one-time purchase, so it needs no card),
///   - Lifetime, a one-time purchase (the launch early-bird price),
///   - Pro Monthly or Pro Yearly, auto-renewing subscriptions in one group.
///
/// Only the App Store build (the Xcode project, which defines APPSTORE)
/// checks any of this. The Swift Package build that `scripts/install.sh`
/// installs is always unlocked.
///
/// Purchases go through Apple's own sheet and daemon, so the app still needs
/// no network entitlement and never sees payment details.
@MainActor
final class Purchases: ObservableObject {
    static let shared = Purchases()

    /// Product IDs. These must match App Store Connect and Drift.storekit.
    enum ID {
        static let trial = "drift.trial"
        static let lifetime = "drift.lifetime"
        static let yearly = "drift.pro.yearly"
        static let monthly = "drift.pro.monthly"
        static let all = [trial, lifetime, yearly, monthly]
        static let plans = [lifetime, yearly, monthly]
    }

    static let trialDays = 7

    enum Access: Equatable {
        /// Not the App Store build, or not checked yet: nothing is blocked.
        case unlocked
        case checking
        case lifetime
        case subscribed(productID: String, renews: Date?)
        case trial(ends: Date)
        case trialEnded
        /// Never started a trial or bought anything.
        case none
    }

    @Published private(set) var access: Access
    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var loadFailed = false
    /// The product being bought right now, for a spinner on its button.
    @Published private(set) var busy: String?
    @Published var message: String?

    private var updates: Task<Void, Never>?
    private var expiry: Timer?

    var isAppStoreBuild: Bool {
        #if APPSTORE
        return true
        #else
        return false
        #endif
    }

    var isUnlocked: Bool {
        switch access {
        case .unlocked, .checking, .lifetime, .subscribed, .trial: return true
        case .trialEnded, .none: return false
        }
    }

    var trialAvailable: Bool {
        if case .none = access { return true }
        return false
    }

    private init() {
        #if APPSTORE
        access = .checking
        #else
        access = .unlocked
        #endif
    }

    /// Call once at launch.
    func start() {
        guard isAppStoreBuild else { return }
        updates = Task.detached { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task {
            await loadProducts()
            await refresh()
        }
    }

    func loadProducts() async {
        guard isAppStoreBuild else { return }
        do {
            let list = try await Product.products(for: ID.all)
            products = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            loadFailed = list.isEmpty
        } catch {
            loadFailed = true
        }
    }

    /// Re-reads what the App Store says this Apple ID owns.
    func refresh() async {
        guard isAppStoreBuild else { return }
        var lifetime = false
        var subscription: (String, Date?)?
        var trialStart: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            switch t.productID {
            case ID.lifetime:
                lifetime = true
            case ID.yearly, ID.monthly:
                if t.expirationDate.map({ $0 > Date() }) ?? true {
                    subscription = (t.productID, t.expirationDate)
                }
            case ID.trial:
                trialStart = t.purchaseDate
            default:
                break
            }
        }
        expiry?.invalidate()
        if lifetime {
            access = .lifetime
        } else if let subscription {
            access = .subscribed(productID: subscription.0, renews: subscription.1)
        } else if let trialStart {
            let ends = trialStart.addingTimeInterval(TimeInterval(Self.trialDays) * 86_400)
            if ends > Date() {
                access = .trial(ends: ends)
                // Lock again the moment the trial runs out, even mid-session.
                let timer = Timer(fire: ends, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in await self?.refresh() }
                }
                RunLoop.main.add(timer, forMode: .common)
                expiry = timer
            } else {
                access = .trialEnded
            }
        } else {
            access = .none
        }
    }

    func buy(_ productID: String) async {
        guard let product = products[productID] else {
            message = "The App Store didn’t respond. Check your connection and try again."
            await loadProducts()
            return
        }
        busy = productID
        defer { busy = nil }
        message = nil
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let t) = verification { await t.finish() }
                await refresh()
            case .pending:
                message = "Waiting for approval. Drift unlocks as soon as it’s approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func startTrial() async { await buy(ID.trial) }

    /// Restore Purchases: asks the App Store to sync this Apple ID's purchases.
    func restore() async {
        busy = "restore"
        defer { busy = nil }
        do {
            try await AppStore.sync()
            await refresh()
            if !isUnlocked { message = "No purchases found for this Apple ID." }
        } catch {
            message = error.localizedDescription
        }
    }

    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    // MARK: Words for the paywall and Settings

    /// A plan as the paywall shows it. Prices come from the App Store; the
    /// fallbacks only show while products load (and in snapshots).
    struct Plan: Identifiable, Equatable {
        let id: String
        let title: String
        let price: String
        let detail: String
        let badge: String?
    }

    var plans: [Plan] {
        ID.plans.compactMap { id in
            let product = products[id]
            // Lifetime is the launch offer: once it's removed from sale in
            // App Store Connect it simply stops appearing here.
            if isAppStoreBuild, !products.isEmpty, product == nil { return nil }
            return Self.plan(id, price: product?.displayPrice)
        }
    }

    static func plan(_ id: String, price: String?) -> Plan {
        switch id {
        case ID.lifetime:
            return Plan(id: id, title: "Lifetime", price: price ?? "$4.99",
                        detail: "Pay once, yours forever. Launch price.", badge: "Early bird")
        case ID.yearly:
            return Plan(id: id, title: "Yearly", price: (price ?? "$9.99") + " / year",
                        detail: "Less than a dollar a month.", badge: "Best value")
        default:
            return Plan(id: id, title: "Monthly", price: (price ?? "$1.99") + " / month",
                        detail: "Cancel any time.", badge: nil)
        }
    }

    var statusLine: String {
        switch access {
        case .unlocked: return "Everything unlocked (developer build)."
        case .checking: return "Checking your purchases…"
        case .lifetime: return "Lifetime: thank you for supporting \(AppInfo.name)."
        case let .subscribed(id, renews):
            let plan = id == ID.yearly ? "Yearly" : "Monthly"
            if let renews { return "\(plan): renews \(renews.formatted(date: .abbreviated, time: .omitted))." }
            return "\(plan) subscription active."
        case let .trial(ends):
            return "Free trial: ends \(ends.formatted(date: .abbreviated, time: .shortened))."
        case .trialEnded: return "Your free trial has ended."
        case .none: return "Try everything free for \(Self.trialDays) days."
        }
    }
}
