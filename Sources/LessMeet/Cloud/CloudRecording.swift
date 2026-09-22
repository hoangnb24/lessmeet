import Foundation

struct CloudMessage: Codable, Equatable {
    let role: String
    let text: String
}

struct CloudRecording: Codable, Equatable {
    let recordingId: String
    let status: String
    let transcript: String?
    let messages: [CloudMessage]
    let error: String?
}
