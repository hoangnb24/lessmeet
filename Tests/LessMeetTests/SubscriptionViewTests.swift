import AppKit
import SwiftUI
import XCTest
@testable import LessMeet

final class SubscriptionViewTests: XCTestCase {
    @MainActor
    func testUnconfiguredPlanRendersWithoutNetwork() throws {
        let account = AccountSession(configuration: try AppConfiguration(clerkPublishableKey: nil, convexSiteURL: nil))
        let billing = BillingStore(publicAppleAPIKey: nil, account: account)
        let subscription = SubscriptionModel(identity: { nil }, token: {
            XCTFail("Signed-out plan must not request a token")
            return ""
        }, fetch: { _, _ in
            XCTFail("Signed-out plan must not request billing")
            throw AccountError("Unexpected network")
        })
        let host = NSHostingView(rootView: SubscriptionView(account: account, billing: billing,
                                                           subscription: subscription, configuration: nil)
            .background(Color.white).environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 640)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 540)
        XCTAssertFalse(billing.isConfigured)
        if let output = ProcessInfo.processInfo.environment["LESSMEET_SUBSCRIPTION_SNAPSHOT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output))
        }
    }
}
