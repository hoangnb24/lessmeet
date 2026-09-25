import Foundation
import CryptoKit

enum BatchChatValidation {
    static func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    static func revision(_ value: Int64) -> Bool { value >= 0 && value <= BatchValidation.safeInteger }
    static func message(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 8192 }
    static func jsonBytes<T: Encodable>(_ value: T) throws -> Int {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value).count
    }
    static func reply(_ value: String) throws -> Bool { try !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && jsonBytes(value) <= 32768 }
    static func digest(_ local: LocalBatch) throws -> String {
        guard let status = local.status, status.state == "complete", local.aggregate?.status == "complete" else { throw AccountError("Complete the batch transcript and refresh its original results before chatting.") }
        try status.validate(manifest: local.manifest, clientID: local.clientBatchId)
        try local.aggregate?.validate(manifest: local.manifest)
        var entries: [String] = []
        for slot in status.chunks {
            guard slot.state == "succeeded", slot.resultAvailable, let raw = local.results["\(slot.index):\(slot.attempt)"] else { throw AccountError("Refresh all selected original results before chatting.") }
            try BatchValidation.require(raw.batchId == status.batchId && raw.index == slot.index && raw.attempt == slot.attempt)
            try raw.validate(manifest: local.manifest)
            let hash = SHA256.hash(data: Data(raw.rawText.utf8)).map { String(format: "%02x", $0) }.joined()
            entries.append("[\(slot.index),\(slot.attempt),\"\(hash)\"]")
        }
        let canonical = "[\"lessmeet.batch.chat.context.v1\",\"\(try local.manifest.digest)\",[\(entries.joined(separator: ","))]]"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct BatchChatRequest: Codable, Equatable {
    let batchId: String
    let clientMessageId: String
    let expectedContextDigest: String
    let expectedHistoryRevision: Int64
    let message: String
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.batchId == rhs.batchId && lhs.clientMessageId == rhs.clientMessageId && lhs.expectedContextDigest == rhs.expectedContextDigest && lhs.expectedHistoryRevision == rhs.expectedHistoryRevision && BatchChatValidation.exact(lhs.message, rhs.message)
    }
    func validate() throws {
        try BatchValidation.require(!batchId.isEmpty && batchId.utf8.count <= 256 && BatchValidation.uuid(clientMessageId) && BatchValidation.hash(expectedContextDigest) && BatchChatValidation.revision(expectedHistoryRevision) && BatchChatValidation.message(message))
        try BatchValidation.require(BatchChatValidation.jsonBytes(self) <= 50176)
    }
}

struct BatchChatOperation: Codable, Equatable {
    let version: Int; let batchId: String; let clientMessageId: String; let revision: Int64
    let contextDigest: String; let state: String; let quota: String
    let text: String?; let error: BatchStatus.Issue?
    var unresolved: Bool { ["queued", "running", "unknown"].contains(state) }
    func validate(batchID: String, request: BatchChatRequest? = nil, previous: BatchChatOperation? = nil) throws {
        try BatchValidation.require(version == 1 && batchId == batchID && BatchValidation.uuid(clientMessageId) && BatchValidation.hash(contextDigest) && revision >= 1 && BatchChatValidation.revision(revision))
        try BatchValidation.require(["queued", "running", "unknown", "succeeded", "failed"].contains(state) && ["reserved", "consumed", "released", "not_enforced"].contains(quota))
        if state == "succeeded" {
            guard let text else { throw AccountError("Missing saved chat reply.") }
            try BatchValidation.require(BatchChatValidation.reply(text) && error == nil && ["consumed", "not_enforced"].contains(quota))
        } else {
            try BatchValidation.require(text == nil)
            try BatchValidation.require((state == "failed" ? ["released", "not_enforced"] : ["reserved", "not_enforced"]).contains(quota))
        }
        if let error { try BatchValidation.require(error.code.utf8.count <= 256 && error.message.utf8.count <= 4096) }
        if let request {
            try request.validate()
            try BatchValidation.require(batchId == request.batchId && clientMessageId == request.clientMessageId && contextDigest == request.expectedContextDigest)
        }
        if let old = previous {
            try BatchValidation.require(old.batchId == batchId && old.clientMessageId == clientMessageId && old.contextDigest == contextDigest && revision >= old.revision)
            if old.state == "unknown" { try BatchValidation.require(["unknown", "succeeded", "failed"].contains(state)) }
            if old.state == "running" { try BatchValidation.require(state != "queued") }
            if !old.unresolved || old.revision == revision {
                try BatchValidation.require(old == self && BatchChatValidation.exact(old.text ?? "", text ?? "") && BatchChatValidation.exact(old.error?.code ?? "", error?.code ?? "") && BatchChatValidation.exact(old.error?.message ?? "", error?.message ?? ""))
            }
        }
    }
}

struct BatchChatStatus: Codable, Equatable {
    struct Exchange: Codable, Equatable {
        let clientMessageId: String; let contextDigest: String; let message: String; let reply: String
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.clientMessageId == rhs.clientMessageId && lhs.contextDigest == rhs.contextDigest && BatchChatValidation.exact(lhs.message, rhs.message) && BatchChatValidation.exact(lhs.reply, rhs.reply)
        }
    }
    let version: Int; let batchId: String; let revision: Int64; let contextDigest: String?
    let availability: String; let exchanges: [Exchange]; let pending: BatchChatOperation?
    func validate(batchID: String, previous: BatchChatStatus? = nil, resolvedPrevious: BatchChatOperation? = nil) throws {
        try BatchValidation.require(version == 1 && batchId == batchID && BatchChatValidation.revision(revision) && revision == Int64(exchanges.count))
        try BatchValidation.require(["ready", "disabled", "incomplete", "context_too_large", "history_full", "busy", "attention"].contains(availability))
        if let contextDigest { try BatchValidation.require(BatchValidation.hash(contextDigest)) }
        try BatchValidation.require(availability != "ready" || (contextDigest != nil && pending == nil && exchanges.count < 20))
        try BatchValidation.require(exchanges.count <= 20 && Set(exchanges.map(\.clientMessageId)).count == exchanges.count)
        var history: [CloudMessage] = []
        for exchange in exchanges {
            try BatchValidation.require(BatchValidation.uuid(exchange.clientMessageId) && BatchValidation.hash(exchange.contextDigest) && BatchChatValidation.message(exchange.message) && BatchChatValidation.reply(exchange.reply))
            history += [.init(role: "user", text: exchange.message), .init(role: "assistant", text: exchange.reply)]
        }
        try BatchValidation.require(BatchChatValidation.jsonBytes(history) <= 128 * 1024)
        if let pending {
            try pending.validate(batchID: batchID)
            try BatchValidation.require(pending.unresolved && !exchanges.contains { $0.clientMessageId == pending.clientMessageId })
        }
        if let previous {
            try BatchValidation.require(previous.batchId == batchId && revision >= previous.revision && exchanges.starts(with: previous.exchanges))
            if let old = previous.pending {
                if let pending, pending.clientMessageId == old.clientMessageId {
                    try pending.validate(batchID: batchID, previous: old)
                } else {
                    guard let terminal = resolvedPrevious else { throw AccountError("A saved pending question disappeared. Resolve its exact identity before continuing.") }
                    try terminal.validate(batchID: batchID, previous: old)
                    try BatchValidation.require(!terminal.unresolved)
                    let exchange = exchanges.first { $0.clientMessageId == terminal.clientMessageId }
                    if terminal.state == "succeeded" {
                        guard let exchange else { throw AccountError("The completed question is not in saved history yet. Refresh again; no new question was sent.") }
                        try BatchValidation.require(exchange.contextDigest == terminal.contextDigest && BatchChatValidation.exact(exchange.reply, terminal.text ?? ""))
                    } else { try BatchValidation.require(exchange == nil) }
                }
            }
        }
    }
}

/// Scoped by the containing recording's account/backend and immutable batch identity.
/// Optional storage keeps recordings written before batch chat decodable.
struct LocalBatchChat: Codable, Equatable {
    var status: BatchChatStatus?
    var request: BatchChatRequest?
    var operation: BatchChatOperation?
    var lastRequest: BatchChatRequest?
    // One bounded status-discovered receipt, without inventing a question payload.
    var observedOperation: BatchChatOperation?
    var confirmedAbsent = false
}
