import Foundation

/// Display-only server snapshot. Cloud authorization always stays on the server.
struct SubscriptionStatus: Decodable, Equatable {
    struct Allowance: Decodable, Equatable {
        let limit: Int
        let used: Int
        let reserved: Int
        var remaining: Int { max(0, limit - used - reserved) }
        var isValid: Bool { [limit, used, reserved].allSatisfy { $0 >= 0 && $0 <= 1_000_000_000 } }
    }
    let userId: String
    let enforcement: Bool
    let plan: String
    let periodEndsAt: Double?
    let transcriptionSeconds: Allowance
    let questions: Allowance

    var periodEnd: Date? { periodEndsAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var isValid: Bool {
        !userId.isEmpty && ["free", "pro", "development"].contains(plan) &&
        (enforcement ? plan != "development" : plan == "development") &&
        transcriptionSeconds.isValid && questions.isValid &&
        (periodEndsAt == nil || (periodEndsAt!.isFinite && periodEndsAt! > 0))
    }
}
