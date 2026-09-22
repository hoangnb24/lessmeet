import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
}

struct Recording: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var duration: TimeInterval = 0
    var status: Status = .recording
    var transcript: String?
    var messages: [ChatMessage] = []
    var failure: String?
    // Cloud caches are scoped to backend + Clerk account, not the shared local library.
    var cloud: [String: CloudRecording]?
    enum Status: String, Codable { case recording, ready, interrupted }
}
