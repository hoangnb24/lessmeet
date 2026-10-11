import XCTest
@testable import LessMeet

final class ResponsesFinalizedOutputTests: XCTestCase {
    private func response(_ id: String = "r", status: String = "completed") -> [String: Any] {
        ["id": id, "object": "response", "status": status, "output": [[String: Any]]()]
    }

    private func created(_ id: String = "r") -> [String: Any] {
        ["type": "response.created", "response": response(id, status: "in_progress")]
    }

    private func completed(_ id: String = "r") -> [String: Any] {
        ["type": "response.completed", "response": response(id)]
    }

    private func message(_ text: String = "Hello", id: String = "m", phase: Any? = nil) -> [String: Any] {
        var item: [String: Any] = ["id": id, "type": "message", "role": "assistant",
            "status": "completed", "content": [["type": "output_text", "text": text]]]
        item["phase"] = phase
        return item
    }

    private func done(_ item: [String: Any]? = nil, index: Any = 0) -> [String: Any] {
        ["type": "response.output_item.done", "output_index": index, "item": item ?? message()]
    }

    private func added(id: String = "m", index: Any = 0, phase: Any? = nil) -> [String: Any] {
        var item = message(id: id, phase: phase)
        item["status"] = "in_progress"
        item["content"] = [[String: Any]]()
        return ["type": "response.output_item.added", "output_index": index, "item": item]
    }

    private func textEvent(_ type: String = "delta", text: String = "Hel", id: String = "m",
                           index: Any = 0, content: Any = 0) -> [String: Any] {
        ["type": "response.output_text." + type, "item_id": id, "output_index": index,
         "content_index": content, type == "delta" ? "delta" : "text": text]
    }

    private func contentEvent(_ type: String, text: String = "", content: Any = 0) -> [String: Any] {
        ["type": "response.content_part." + type, "item_id": "m", "output_index": 0,
         "content_index": content, "part": ["type": "output_text", "text": text]]
    }

    private func output(_ events: [[String: Any]], budget: Int = 100_000,
                        terminal: [String: Any]? = nil) -> [[String: Any]]? {
        var ledger = ResponsesFinalizedOutput(maximumBytes: budget)
        for event in events { ledger.observe(event) }
        return ledger.output(for: terminal ?? response())
    }

    private func texts(_ items: [[String: Any]]?) -> [String]? {
        items?.flatMap { ($0["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }
    }

    func testFinalizedOnlyAndIntegrationPrefixWithSuffix() {
        XCTAssertEqual(texts(output([created(), done(), completed()])), ["Hello"])
        var events = [created(), added(), textEvent(), done(), completed()]
        for index in events.indices { events[index]["sequence_number"] = index }
        XCTAssertEqual(texts(output(events)), ["Hello"])
        // Sequence fields are not required and do not override arrival order.
        events[2]["sequence_number"] = 0
        XCTAssertEqual(texts(output(events)), ["Hello"])
    }

    func testFullContentLifecycleAndOptionalTextDone() {
        let before = [created(), added(), contentEvent("added"), textEvent()]
        XCTAssertEqual(texts(output(before + [textEvent("done", text: "Hello"),
            contentEvent("done", text: "Hello"), done(), completed()])), ["Hello"])
        XCTAssertEqual(texts(output(before + [contentEvent("done", text: "Hello"),
            done(), completed()])), ["Hello"])
    }

    func testOriginalItemAndContentOrderWithCommentaryAndReasoningFiltered() {
        var first = message(id: "first", phase: NSNull())
        first["content"] = [["type": "output_text", "text": "A"], ["type": "output_text", "text": "B"]]
        let reasoning: [String: Any] = ["id": "reasoning", "type": "reasoning", "summary": []]
        let events = [created(), done(message("C", id: "last", phase: "final_answer"), index: 3),
                      done(message("ignored", id: "comment", phase: "commentary"), index: 1),
                      done(reasoning, index: 2), done(first), completed()]
        let result = output(events)
        XCTAssertEqual(result?.compactMap { $0["id"] as? String }, ["first", "last"])
        XCTAssertEqual(texts(result), ["A", "B", "C"])
        XCTAssertEqual(texts(output([created(), done(message(phase: "commentary")), completed()])), [])
        XCTAssertEqual(texts(output([created(), done(reasoning), completed()])), [])
    }

    func testCreatedRequiredExactlyOnceAndMatchingTerminal() {
        XCTAssertNil(output([done(), completed()]))
        XCTAssertNil(output([created(), created(), done(), completed()]))
        XCTAssertNil(output([created(), created("other"), done(), completed()]))
        XCTAssertNil(output([created(), done(), completed("other")]))
        XCTAssertNil(output([created(), done(), completed()], terminal: response("other")))
        for field in ["id", "object", "status", "output"] {
            var invalid = response(status: "in_progress")
            invalid.removeValue(forKey: field)
            XCTAssertNil(output([["type": "response.created", "response": invalid], done(), completed()]))
        }
        for status in ["completed", "failed", "incomplete", "queued"] {
            XCTAssertNil(output([["type": "response.created", "response": response(status: status)], done(), completed()]))
        }
        for field in ["error", "incomplete_details"] {
            var invalid = response(status: "in_progress")
            invalid[field] = ["message": "private payload"]
            XCTAssertNil(output([["type": "response.created", "response": invalid], done(), completed()]))
        }
    }

    func testCompletionAndExactlyEmptyTypedOutputRequired() {
        XCTAssertNil(output([created(), done()]))
        for invalid: Any in [NSNull(), "", ["output": ""], [message()]] {
            var terminal = response()
            terminal["output"] = invalid
            XCTAssertNil(output([created(), done(), completed()], terminal: terminal))
        }
        var missing = response()
        missing.removeValue(forKey: "output")
        XCTAssertNil(output([created(), done(), completed()], terminal: missing))
        XCTAssertNil(output([created(), done(), completed(), done()]))
    }

    func testIdentityConflictsAndDuplicateIDs() {
        XCTAssertNil(output([created(), added(), done(message(id: "other")), completed()]))
        XCTAssertNil(output([created(), done(), done(index: 1), completed()]))
        XCTAssertNil(output([created(), textEvent(id: "other"), done(), completed()]))
        XCTAssertNil(output([created(), done(message(id: "")), completed()]))
        let reasoning: [String: Any] = ["id": "m", "type": "reasoning"]
        XCTAssertNil(output([created(), added(), done(reasoning), completed()]))
    }

    func testIndicesRejectBoolFractionNegativeStringHugeAndGaps() {
        let invalid: [Any] = [true, false, -1, 0.5, "0", NSNull(), Int.max, Double.infinity, Double.nan]
        for index in invalid {
            XCTAssertNil(output([created(), done(index: index), completed()]))
            XCTAssertNil(output([created(), textEvent(content: index), done(), completed()]))
        }
        XCTAssertNil(output([created(), done(index: 1), completed()]))
        XCTAssertNil(output([created(), done(index: 64), completed()]))
        XCTAssertNil(output([created(), textEvent(content: 128), done(), completed()]))
        XCTAssertNil(output([created(), textEvent(content: 1), done(), completed()]))
        XCTAssertNil(output([created(), textEvent(index: 1), done(), completed()]))
    }

    func testDuplicateUnfinalizedAndOutOfOrderEvents() {
        for events in [
            [created(), done(), done(), completed()],
            [created(), added(), added(), done(), completed()],
            [created(), added(), completed()],
            [created(), textEvent(), completed()],
            [created(), added(id: "other", index: 1), done(), completed()],
            [created(), done(), textEvent(), completed()],
            [created(), textEvent(), added(), done(), completed()],
            [created(), contentEvent("added"), contentEvent("added"), done(), completed()],
            [created(), textEvent(text: ""), contentEvent("added"), done(), completed()],
            [created(), textEvent("done", text: "Hello"), textEvent(), done(), completed()],
            [created(), textEvent("done", text: "Hello"), textEvent("done", text: "Hello"), done(), completed()],
            [created(), contentEvent("done", text: "Hello"), contentEvent("done", text: "Hello"), done(), completed()]
        ] { XCTAssertNil(output(events)) }
    }

    func testContentConflictAndUTF8Exactness() {
        for events in [
            [created(), textEvent(text: "Wrong"), done(), completed()],
            [created(), textEvent("done", text: "Hel"), done(), completed()],
            [created(), contentEvent("done", text: "Hel"), done(), completed()],
            [created(), textEvent("done", text: "Hello"), contentEvent("done", text: "Other"), done(), completed()],
            [created(), textEvent(text: "Hello!"), done(), completed()],
            [created(), contentEvent("added", text: "nonempty"), done(), completed()],
            [created(), textEvent(text: "é"), done(message("e\u{301}")), completed()],
            [created(), textEvent("done", text: "é"), done(message("e\u{301}")), completed()]
        ] { XCTAssertNil(output(events)) }
        XCTAssertEqual(texts(output([created(), textEvent(text: "👋"), done(message("👋 there")), completed()])), ["👋 there"])
    }

    func testPhasesStatusesRolesUnsupportedAndRefusal() {
        for phase: Any in ["unknown", "", 1, true] {
            XCTAssertNil(output([created(), done(message(phase: phase)), completed()]))
        }
        XCTAssertNil(output([created(), added(phase: "commentary"), done(message(phase: "final_answer")), completed()]))
        XCTAssertNil(output([created(), added(phase: "commentary"), done(), completed()]))
        for status in ["in_progress", "incomplete", "failed", "unknown"] {
            var item = message()
            item["status"] = status
            XCTAssertNil(output([created(), done(item), completed()]))
        }
        for role in ["user", "system", "tool"] {
            var item = message()
            item["role"] = role
            XCTAssertNil(output([created(), done(item), completed()]))
        }
        for type in ["function_call", "unknown", "output_audio", "refusal"] {
            var item = message()
            item["type"] = type
            XCTAssertNil(output([created(), done(item), completed()]))
            item = message()
            item["content"] = [["type": type, "text": "Hello"]]
            XCTAssertNil(output([created(), done(item), completed()]))
        }
        var item = message()
        item["refusal"] = "private refusal"
        XCTAssertNil(output([created(), done(item), completed()]))
        item = message()
        item["content"] = [["type": "output_text", "text": "Hello", "refusal": "private refusal"]]
        XCTAssertNil(output([created(), done(item), completed()]))
    }

    func testUnknownFailureAndRefusalEventsDisableOnlyFallback() {
        for type in ["error", "response.failed", "response.incomplete", "response.refusal.delta",
                     "response.refusal.done", "response.unknown"] {
            XCTAssertNil(output([created(), done(), ["type": type, "message": "private payload"], completed()]))
        }
        XCTAssertNil(output([created(), done(), [:], completed()]))
        XCTAssertNil(output([created(), done(), ["type": 42], completed()]))
    }

    func testBudgetAndCountCapsDisablePermanently() {
        for budget in [Int.min, -1, 0, 1, 385, 390] {
            XCTAssertNil(output([created(), done(), completed()], budget: budget))
        }
        // r(1) + item(256) + m(1) + part(128) + Hello(5) = 391.
        XCTAssertEqual(texts(output([created(), done(), completed()], budget: 391)), ["Hello"])
        XCTAssertNil(output([created(), done(message("👋")), completed()], budget: 389))
        XCTAssertEqual(texts(output([created(), done(message("👋")), completed()], budget: 390)), ["👋"])
        XCTAssertNil(output([created(), textEvent(text: String(repeating: "x", count: 1000)), done(), completed()], budget: 500))
        var many = message()
        many["content"] = Array(repeating: ["type": "output_text", "text": ""], count: 129)
        XCTAssertNil(output([created(), done(many), completed()]))
        many["content"] = Array(repeating: ["type": "output_text", "text": ""], count: 128)
        var second = many
        second["id"] = "second"
        XCTAssertNil(output([created(), done(many), done(second, index: 1),
                             done(message(id: "third"), index: 2), completed()]))
        var ledger = ResponsesFinalizedOutput(maximumBytes: 500)
        for event in [created(), textEvent(text: String(repeating: "x", count: 1000)), created(), done(), completed()] {
            ledger.observe(event)
        }
        XCTAssertNil(ledger.output(for: response()))
    }

    func testNormalizedOutputContainsOnlyExtractionFields() {
        var item = message()
        item["private_unused"] = "not retained"
        item["content"] = [["type": "output_text", "text": "Hello", "annotations": ["private annotation"]]]
        let result = output([created(), done(item), completed()])
        XCTAssertEqual(Set(result?.first?.keys.map { $0 } ?? []), ["id", "type", "role", "status", "content"])
        let part = (result?.first?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(Set(part?.keys.map { $0 } ?? []), ["type", "text"])
    }

    func testInvalidationDiscardsPayloadWithoutDiagnosticLogging() throws {
        var ledger = ResponsesFinalizedOutput(maximumBytes: 100_000)
        let secret = "private-ledger-fixture"
        ledger.observe(created(secret))
        ledger.observe(done(message(secret, id: secret)))
        ledger.observe(["type": "error", "message": secret])
        XCTAssertNil(ledger.output(for: response(secret)))
        XCTAssertFalse(String(reflecting: ledger).contains(secret))
        // Static guard complements the nonthrowing API. No error payload is logged.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/LessMeet/ChatGPTChat/ResponsesFinalizedOutput.swift"), encoding: .utf8)
        for loggingCall in ["print(", "debugPrint(", "NSLog(", "Logger(", "os_log(", "FileHandle"] {
            XCTAssertFalse(source.contains(loggingCall))
        }
    }
}
