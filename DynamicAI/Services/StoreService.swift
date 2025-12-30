import Foundation
import StoreKit
import Combine

/// StoreKit 2 service for in-app purchases
@MainActor
class StoreService: ObservableObject {
    static let shared = StoreService()

    // Product IDs - configure these in App Store Connect
    enum ProductID: String, CaseIterable {
        case proMonthly = "com.dynamicai.pro.monthly"
        case proYearly = "com.dynamicai.pro.yearly"
        case byok = "com.dynamicai.byok" // Bring Your Own Key - one-time purchase
    }

    @Published var products: [Product] = []
    @Published var purchasedProductIDs: Set<String> = []
    @Published var isLoading = false

    private var updateListenerTask: Task<Void, Error>?

    var isPro: Bool {
        purchasedProductIDs.contains(ProductID.proMonthly.rawValue) ||
        purchasedProductIDs.contains(ProductID.proYearly.rawValue)
    }

    var hasByok: Bool {
        purchasedProductIDs.contains(ProductID.byok.rawValue)
    }

    var canMakeQueries: Bool {
        // Pro users: unlimited
        if isPro { return true }

        // Users with their own API key: unlimited (they're paying Anthropic directly)
        if KeychainService.shared.hasAPIKey(for: .anthropic) {
            return true
        }

        // Free users: check daily limit
        UserDefaults.standard.resetDailyCountIfNeeded()
        return UserDefaults.standard.dailyQueryCount < freeQueryLimit
    }

    let freeQueryLimit = 15

    var remainingFreeQueries: Int {
        max(0, freeQueryLimit - UserDefaults.standard.dailyQueryCount)
    }

    private init() {
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await updatePurchasedProducts()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let productIDs = ProductID.allCases.map { $0.rawValue }
            products = try await Product.products(for: productIDs)
        } catch {
            print("Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws -> Transaction? {
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await updatePurchasedProducts()
            await transaction.finish()
            return transaction

        case .userCancelled:
            return nil

        case .pending:
            return nil

        @unknown default:
            return nil
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await updatePurchasedProducts()
        } catch {
            print("Failed to restore purchases: \(error)")
        }
    }

    // MARK: - Transaction Updates

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)
                    await self.updatePurchasedProducts()
                    await transaction.finish()
                } catch {
                    print("Transaction verification failed: \(error)")
                }
            }
        }
    }

    private func updatePurchasedProducts() async {
        var purchased: Set<String> = []

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                switch transaction.productType {
                case .autoRenewable:
                    if transaction.revocationDate == nil {
                        purchased.insert(transaction.productID)
                    }
                case .nonConsumable:
                    if transaction.revocationDate == nil {
                        purchased.insert(transaction.productID)
                    }
                default:
                    break
                }
            } catch {
                print("Failed to verify transaction: \(error)")
            }
        }

        purchasedProductIDs = purchased

        // Sync with UserDefaults for quick access
        UserDefaults.standard.isPro = isPro
        UserDefaults.standard.hasByok = hasByok
    }

    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Query Tracking

    func incrementQueryCount() {
        UserDefaults.standard.resetDailyCountIfNeeded()
        UserDefaults.standard.dailyQueryCount += 1
    }
}

enum StoreError: Error {
    case failedVerification
}
