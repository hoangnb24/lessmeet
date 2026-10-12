import Foundation
import CoreFoundation

/// A conservative, optional ledger. Failure never rejects the canonical response.
/// Lifecycle: created precedes all item events. Added events are optional, but must
/// precede content events. Deltas precede text/content done; item done is final.
/// Item done alone can finalize text. Its text may extend the observed UTF-8 prefix.
/// A matching completed event must be observed before extraction. Unknown events
/// disable the ledger, including unsupported reasoning-summary streaming events.
/// Arrival order is authoritative; sequence_number is neither required nor retained.
/// Caps: 64 items, 128 parts per item, 256 parts total. Indices must fit these caps.
/// The budget charges retained UTF-8 bytes plus 256 bytes/item and 128 bytes/part.
/// Replacement strings are charged again (conservatively); Swift allocator overhead
/// is implementation-dependent. No event dictionaries or diagnostic payloads are kept.
struct ResponsesFinalizedOutput {
    private struct Part {
        var prefix = ""
        var textDone: String?
        var contentDone: String?
        var final: String?
        var added = false
    }

    private struct Item {
        var id: String
        var added = false
        var kind: String?
        var phase: String?
        var done = false
        var parts: [Int: Part] = [:]
    }

    private let maximumBytes: Int
    private var usedBytes = 0
    private var valid = true
    private var responseID: String?
    private var items: [Int: Item] = [:]
    private var partCount = 0
    private var completed = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        valid = maximumBytes > 0
    }

    mutating func observe(_ event: [String: Any]) {
        guard valid else { return }
        if !accept(event) {
            valid = false
            responseID = nil
            items.removeAll(keepingCapacity: false)
            usedBytes = 0
            partCount = 0
        }
    }

    /// The caller validates the terminal envelope, output size, nonblank answer,
    /// and global emitted UTF-8 prefix. This helper never substitutes for completion.
    func output(for response: [String: Any]) -> [[String: Any]]? {
        guard valid, completed, let responseID, let terminalID = response["id"] as? String,
              Self.equal(terminalID, responseID),
              let output = response["output"] as? [Any], output.isEmpty,
              !items.isEmpty, items.keys.sorted() == Array(0..<items.count),
              items.values.allSatisfy({ $0.done }) else { return nil }
        var result: [[String: Any]] = []
        for index in 0..<items.count {
            guard let item = items[index] else { return nil }
            // Reasoning has been explicitly finalized but cannot supply an answer.
            guard item.kind == "message", item.phase != "commentary" else { continue }
            let content: [[String: Any]] = (0..<item.parts.count).compactMap { index in
                guard let text = item.parts[index]?.final else { return nil }
                return ["type": "output_text", "text": text]
            }
            guard content.count == item.parts.count else { return nil }
            var normalized: [String: Any] = ["id": item.id, "type": "message",
                "role": "assistant", "status": "completed", "content": content]
            if let phase = item.phase { normalized["phase"] = phase }
            result.append(normalized)
        }
        return result
    }

    private mutating func charge(_ bytes: Int) -> Bool {
        guard bytes >= 0, bytes <= maximumBytes - usedBytes else { return false }
        usedBytes += bytes
        return true
    }

    private static func index(_ value: Any?, cap: Int) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(cap),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func phase(_ object: [String: Any]) -> (valid: Bool, value: String?) {
        guard let raw = object["phase"], !(raw is NSNull) else { return (true, nil) }
        guard let value = raw as? String, ["commentary", "final_answer"].contains(value) else {
            return (false, nil)
        }
        return (true, value)
    }

    private static func text(_ part: [String: Any]) -> String? {
        guard part["type"] as? String == "output_text", part["refusal"] == nil else { return nil }
        return part["text"] as? String
    }

    private static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.utf8.starts(with: prefix.utf8)
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func agrees(_ observed: String?, with text: String) -> Bool {
        observed.map { equal($0, text) } ?? true
    }

    private mutating func accept(_ event: [String: Any]) -> Bool {
        guard let type = event["type"] as? String, !completed else { return false }
        if type == "response.created" {
            guard responseID == nil, let response = event["response"] as? [String: Any],
                  let id = response["id"] as? String, !id.isEmpty,
                  response["object"] as? String == "response",
                  response["status"] as? String == "in_progress",
                  response["error"] == nil || response["error"] is NSNull,
                  response["incomplete_details"] == nil || response["incomplete_details"] is NSNull,
                  let output = response["output"] as? [Any], output.isEmpty,
                  charge(id.utf8.count) else { return false }
            responseID = id
            return true
        }
        guard responseID != nil else { return false }
        if type == "response.completed" {
            guard let response = event["response"] as? [String: Any],
                  let id = response["id"] as? String, Self.agrees(responseID, with: id) else { return false }
            completed = true
            return true // The caller validates this envelope before output(for:).
        }
        if type == "response.in_progress" {
            guard let response = event["response"] as? [String: Any],
                  let id = response["id"] as? String, Self.agrees(responseID, with: id) else { return false }
            return true
        }
        let itemEvent = type == "response.output_item.added" || type == "response.output_item.done"
        let contentEvents = ["response.content_part.added", "response.content_part.done",
                             "response.output_text.delta", "response.output_text.done"]
        guard itemEvent || contentEvents.contains(type),
              let index = Self.index(event["output_index"], cap: 64) else { return false }
        let object = event["item"] as? [String: Any]
        guard let id = (itemEvent ? object?["id"] : event["item_id"]) as? String,
              !id.isEmpty else { return false }
        var item: Item
        if let existing = items[index] {
            guard Self.equal(existing.id, id), !existing.done else { return false }
            item = existing
        } else {
            guard !items.values.contains(where: { $0.id == id }), charge(256),
                  charge(id.utf8.count) else { return false }
            item = Item(id: id)
        }
        if itemEvent {
            guard let object, let kind = object["type"] as? String,
                  kind == "message" || kind == "reasoning",
                  item.kind == nil || item.kind == kind else { return false }
            let phase = Self.phase(object)
            guard phase.valid, item.phase == nil || item.phase == phase.value else { return false }
            item.kind = kind
            item.phase = phase.value
            if kind == "message" {
                guard object["role"] as? String == "assistant", object["refusal"] == nil,
                      let content = object["content"] as? [[String: Any]], content.count <= 128 else { return false }
                if type == "response.output_item.added" {
                    guard !item.added, item.parts.isEmpty, content.isEmpty,
                          object["status"] as? String == "in_progress" else { return false }
                } else {
                    guard object["status"] as? String == "completed",
                          item.parts.keys.allSatisfy({ $0 < content.count }) else { return false }
                    for (partIndex, raw) in content.enumerated() {
                        guard let text = Self.text(raw), charge(text.utf8.count) else { return false }
                        var part: Part
                        if let existing = item.parts[partIndex] { part = existing }
                        else {
                            guard allocatePart() else { return false }
                            part = Part()
                        }
                        guard Self.hasPrefix(text, part.prefix),
                              Self.agrees(part.textDone, with: text),
                              Self.agrees(part.contentDone, with: text) else { return false }
                        part.final = text
                        item.parts[partIndex] = part
                    }
                }
            } else {
                guard item.parts.isEmpty, phase.value == nil,
                      object["content"] == nil, object["refusal"] == nil else { return false }
                // Reasoning status is optional in the schema. The done event is required.
                if let status = object["status"], !(status is NSNull) {
                    guard status as? String == (type == "response.output_item.done" ? "completed" : "in_progress") else { return false }
                }
                if type == "response.output_item.added", item.added { return false }
            }
            if type == "response.output_item.done" { item.done = true }
            else { item.added = true }
        } else {
            guard item.kind == nil || item.kind == "message",
                  let partIndex = Self.index(event["content_index"], cap: 128) else { return false }
            if type == "response.content_part.added", item.parts[partIndex] != nil { return false }
            var part: Part
            if let existing = item.parts[partIndex] { part = existing }
            else {
                guard allocatePart() else { return false }
                part = Part()
            }
            switch type {
            case "response.output_text.delta":
                guard part.textDone == nil, part.contentDone == nil,
                      let delta = event["delta"] as? String, charge(delta.utf8.count) else { return false }
                part.prefix += delta
            case "response.output_text.done":
                guard part.textDone == nil, part.contentDone == nil,
                      let text = event["text"] as? String, Self.hasPrefix(text, part.prefix),
                      charge(text.utf8.count) else { return false }
                part.textDone = text
            case "response.content_part.added":
                guard !part.added, part.prefix.isEmpty, part.textDone == nil, part.contentDone == nil,
                      let raw = event["part"] as? [String: Any], Self.text(raw) == "" else { return false }
                part.added = true
            case "response.content_part.done":
                guard part.contentDone == nil, let raw = event["part"] as? [String: Any],
                      let text = Self.text(raw), Self.hasPrefix(text, part.prefix),
                      Self.agrees(part.textDone, with: text),
                      charge(text.utf8.count) else { return false }
                part.contentDone = text
            default: return false
            }
            item.parts[partIndex] = part
        }
        items[index] = item
        return true
    }

    private mutating func allocatePart() -> Bool {
        guard partCount < 256, charge(128) else { return false }
        partCount += 1
        return true
    }
}
