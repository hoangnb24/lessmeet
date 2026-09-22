import Foundation

/// Keeps the submitted question visible and recoverable until the request settles.
struct RecordingChatDraft {
    var text = ""
    private(set) var pending: String?

    var canSubmit: Bool {
        pending == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 8 * 1024
    }

    mutating func beginSubmission() -> String? {
        guard canSubmit else { return nil }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = question
        text = ""
        return question
    }

    mutating func finishSubmission(failed: Bool) {
        if failed, let pending, text.isEmpty { text = pending }
        pending = nil
    }
}
