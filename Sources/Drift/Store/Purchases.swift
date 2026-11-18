import AppKit
import Foundation
import StoreKit

/// What the person has paid for, read from the App Store with StoreKit 2.
///
/// Drift is a free download that unlocks with a purchase before first use
/// (no free trial). Every feature is in every plan:
///   - Lifetime, a one-time purchase, sold only during the launch promotion
///     (remove it from sale in App Store Connect and it disappears here),
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
        static let lifetime = "drift.lifetime"
        static let yearly = "drift.pro.yearly"
        static let monthly = "drift.pro.monthly"
        static let all = [lifetime, yearly, monthly]
        static let plans = [lifetime, yearly, monthly]
    }

    enum Access: Equatable {
        /// Not the App Store build, or not checked yet: nothing is blocked.
        case unlocked
        case checking
        case lifetime
        case subscribed(productID: String, renews: Date?)
        /// Nothing bought yet, or a subscription that has lapsed.
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
        case .unlocked, .checking, .lifetime, .subscribed: return true
        case .none: return false
        }
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
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            switch t.productID {
            case ID.lifetime:
                lifetime = true
            case ID.yearly, ID.monthly:
                if t.expirationDate.map({ $0 > Date() }) ?? true {
                    subscription = (t.productID, t.expirationDate)
                }
            default:
                break
            }
        }
        expiry?.invalidate()
        if lifetime {
            access = .lifetime
        } else if let subscription {
            access = .subscribed(productID: subscription.0, renews: subscription.1)
            // Check again just after it's due to renew, so a lapse is noticed.
            if let due = subscription.1 {
                let timer = Timer(fire: due.addingTimeInterval(60), interval: 0, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in await self.refresh() }
                }
                RunLoop.main.add(timer, forMode: .common)
                expiry = timer
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
                message = "Waiting for approval. \(AppInfo.name) unlocks as soon as it’s approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

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
                        detail: "Pay once, yours forever. Launch offer only.", badge: "Launch offer")
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
        case .none: return "Choose a plan to start using \(AppInfo.name)."
        }
    }
}
