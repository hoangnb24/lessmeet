import Foundation
import RevenueCat

/// The sole owner of the process-global Purchases instance. Do not configure Purchases elsewhere.
@MainActor
final class RevenueCatBillingDriver: BillingDriver {
    static let shared = RevenueCatBillingDriver()
    private var purchases: Purchases?
    private var configuredKey: String?
    private var offered: [String: Package] = [:]
    private var offeringUserID: String?
    private init() {}

    private enum Failure: Error { case configurationConflict, identityMismatch, unavailablePackage }

    func identify(publicAppleAPIKey: String, userID: String) async throws {
        guard !userID.isEmpty, !userID.hasPrefix("$RCAnonymousID:") else {
            throw Failure.identityMismatch
        }
        if purchases?.appUserID != userID {
            offered = [:]
            offeringUserID = nil
        }
        if purchases == nil {
            // Never adopt or reconfigure an unrelated singleton, even with the same user ID.
            guard !Purchases.isConfigured else { throw Failure.configurationConflict }
            purchases = Purchases.configure(withAPIKey: publicAppleAPIKey, appUserID: userID)
            configuredKey = publicAppleAPIKey
        }
        guard configuredKey == publicAppleAPIKey, let purchases else { throw Failure.configurationConflict }
        if purchases.appUserID != userID { _ = try await purchases.logIn(userID) }
        _ = try identified(userID)
    }

    func packages(userID: String) async throws -> [BillingPackage] {
        let purchases = try identified(userID)
        let offerings = try await purchases.offerings()
        _ = try identified(userID)
        var result: [BillingPackage] = []
        offered = [:]
        for package in offerings.current?.availablePackages ?? [] {
            let product = package.storeProduct
            guard let subscription = product.subscriptionPeriod, subscription.value == 1 else { continue }
            let period: BillingPackage.Period
            switch subscription.unit {
            case .month: period = .monthly
            case .year: period = .yearly
            default: continue
            }
            let item = BillingPackage(id: package.identifier, productID: product.productIdentifier,
                                      title: product.localizedTitle, localizedPrice: product.localizedPriceString,
                                      period: period)
            guard item.isSupported, offered[item.id] == nil else { continue }
            offered[item.id] = package
            result.append(item)
        }
        offeringUserID = userID
        return result
    }

    func purchase(packageID: String, userID: String) async throws -> BillingPurchaseResult {
        let purchases = try identified(userID)
        guard offeringUserID == userID, let package = offered[packageID] else {
            throw Failure.unavailablePackage
        }
        do {
            let result = try await purchases.purchase(package: package)
            _ = try identified(userID)
            return BillingPurchaseResult(cancelled: result.userCancelled,
                                         hasProEntitlement: result.customerInfo.entitlements["lessmeet_pro"]?.isActive == true)
        } catch {
            if Self.isPurchaseCancellation(error) {
                return BillingPurchaseResult(cancelled: true, hasProEntitlement: false)
            }
            throw error
        }
    }

    static func isPurchaseCancellation(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == ErrorCode.errorDomain && value.code == ErrorCode.purchaseCancelledError.rawValue
    }

    func restore(userID: String) async throws -> Bool {
        let purchases = try identified(userID)
        let info = try await purchases.restorePurchases()
        _ = try identified(userID)
        return info.entitlements["lessmeet_pro"]?.isActive == true
    }

    private func identified(_ userID: String) throws -> Purchases {
        guard let purchases, Purchases.isConfigured, Purchases.shared === purchases,
              !purchases.isAnonymous, purchases.appUserID == userID else { throw Failure.identityMismatch }
        return purchases
    }
}
