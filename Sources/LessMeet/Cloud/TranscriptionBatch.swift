import Foundation
import CryptoKit
import CoreMedia
import CoreFoundation

enum BatchValidation {
    static let safeInteger: Int64 = 9_007_199_254_740_991
    static func require(_ condition: Bool) throws { if !condition { throw CloudClientError(message: "Invalid batch data. Local audio is preserved; refresh before continuing.") } }
    static func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func multiply(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.multipliedReportingOverflow(by: b); try require(!result.overflow); return result.partialValue
    }
}

struct BatchManifest: Codable, Equatable {
    struct Rational: Codable, Equatable {
        let value: Int64
        let timescale: Int32
        init(value: Int64, timescale: Int32) throws {
            try BatchValidation.require(value > 0 && timescale > 0)
            var a = value, b = Int64(timescale)
            while b != 0 { (a, b) = (b, a % b) }
            self.value = value / a; self.timescale = Int32(Int64(timescale) / a)
            try validate()
        }
        func validate() throws {
            try BatchValidation.require(value > 0 && timescale > 0 && value <= BatchValidation.safeInteger)
            try BatchValidation.require(value <= BatchValidation.multiply(7200, Int64(timescale)))
            var a = value, b = Int64(timescale)
            while b != 0 { (a, b) = (b, a % b) }
            try BatchValidation.require(a == 1)
        }
        var time: CMTime { CMTime(value: value, timescale: timescale) }
        var enclosingMilliseconds: Int64 { get throws {
            try validate(); let numerator = try BatchValidation.multiply(value, 1000)
            return numerator / Int64(timescale) + (numerator % Int64(timescale) == 0 ? 0 : 1)
        } }
    }
    struct File: Codable, Equatable { let sha256: String; let bytes: Int64 }
    struct Source: Codable, Equatable { let sha256: String; let bytes: Int64; let duration: Rational }
    let version: Int
    let source: Source
    let chunks: [File]

    init(prepared: TranscriptionChunks.Manifest) throws {
        let duration = try Rational(value: prepared.sourceDuration.value, timescale: prepared.sourceDuration.timescale)
        version = 1
        source = Source(sha256: prepared.source.sha256, bytes: Int64(prepared.source.bytes), duration: duration)
        chunks = prepared.chunks.map { File(sha256: $0.file.sha256, bytes: Int64($0.file.bytes)) }
        let windows = try TranscriptionChunks.windows(duration: duration.time)
        try BatchValidation.require(prepared.version == 1 && windows.count == prepared.chunks.count)
        for (window, actual) in zip(windows, prepared.chunks) {
            try BatchValidation.require(window.index == actual.window.index && window.range == actual.window.range && actual.presentationDuration.cmTime == window.range.duration)
        }
        try validate()
    }
    func validate() throws {
        try source.duration.validate()
        try BatchValidation.require(version == 1 && BatchValidation.hash(source.sha256) && source.bytes > 0 && source.bytes <= BatchValidation.safeInteger)
        let count = try TranscriptionChunks.windows(duration: source.duration.time).count
        try BatchValidation.require(chunks.count == count && count <= 25)
        for file in chunks { try BatchValidation.require(BatchValidation.hash(file.sha256) && file.bytes > 0 && file.bytes <= 18 * 1024 * 1024) }
    }
    var canonical: String { get throws {
        try validate()
        let slots = chunks.enumerated().map { "[\($0.offset),\"\($0.element.sha256)\",\($0.element.bytes)]" }.joined(separator: ",")
        return "[\"lessmeet.batch.geometry.v1\",\"\(source.sha256)\",\(source.bytes),\(source.duration.value),\(source.duration.timescale),[\(slots)]]"
    } }
    var digest: String { get throws { SHA256.hash(data: Data(try canonical.utf8)).map { String(format: "%02x", $0) }.joined() } }
}

struct BatchStatus: Codable, Equatable {
    struct Issue: Codable, Equatable { let code: String; let message: String }
    struct Slot: Codable, Equatable {
        let index: Int; let state: String; let attempt: Int; let fence: Int64
        let retryAllowed: Bool; let resultAvailable: Bool; let error: Issue?
    }
    struct Aggregate: Codable, Equatable { let state: String; let available: Bool }
    let version: Int; let batchId: String; let clientBatchId: String; let manifestDigest: String
    let revision: Int64; let state: String; let quotaSeconds: Int64; var chunks: [Slot]
    let aggregate: Aggregate; let cleanupPending: Bool
    func validate(manifest: BatchManifest, clientID: String) throws {
        try manifest.validate()
        try BatchValidation.require(version == 1 && !batchId.isEmpty && batchId.utf8.count <= 256 && clientBatchId == clientID && BatchValidation.uuid(clientID))
        try BatchValidation.require(manifestDigest == manifest.digest && revision >= 0 && revision <= BatchValidation.safeInteger)
        let d = manifest.source.duration
        try BatchValidation.require(quotaSeconds == d.value / Int64(d.timescale) + (d.value % Int64(d.timescale) == 0 ? 0 : 1))
        try BatchValidation.require(["uploading", "queued", "processing", "attention", "complete", "partial", "failed"].contains(state))
        try BatchValidation.require(["pending", "complete", "partial", "too_large"].contains(aggregate.state) && chunks.count == manifest.chunks.count)
        for (index, slot) in chunks.enumerated() {
            try BatchValidation.require(slot.index == index && (0...2).contains(slot.attempt) && slot.fence >= 0 && slot.fence <= BatchValidation.safeInteger)
            try BatchValidation.require(["missing", "admitting", "uploaded", "queued", "running", "unknown", "succeeded", "failed"].contains(slot.state))
            try BatchValidation.require(!slot.retryAllowed || (slot.state == "failed" && slot.attempt == 1))
            try BatchValidation.require(!slot.resultAvailable || (slot.state == "succeeded" && slot.attempt > 0))
        }
    }
}

struct BatchRawResult: Codable, Equatable {
    let version: Int; let batchId: String; let index: Int; let attempt: Int; let rawText: String
    func validate(manifest: BatchManifest) throws {
        let windows = try TranscriptionChunks.windows(duration: manifest.source.duration.time)
        try BatchValidation.require(windows.indices.contains(index) && rawText.utf8.count <= 384 * 1024)
        let duration = windows[index].range.duration
        let end = try BatchValidation.multiply(duration.value, 1000) / Int64(duration.timescale)
        let bytes = Data(rawText.utf8)
        let value = try JSONSerialization.jsonObject(with: bytes)
        let root = try Self.exact(value, keys: ["version", "segments"])
        try BatchValidation.require(Self.integer(root["version"]) == 1)
        guard let segments = root["segments"] as? [Any] else { try BatchValidation.require(false); return }
        try BatchValidation.require(segments.count <= 2048)
        for value in segments {
            let segment = try Self.exact(value, keys: ["startMs", "endMs", "speaker", "text"])
            try BatchValidation.require(Self.validText(segment["text"], maxBytes: 8192) && (segment["speaker"] is NSNull || Self.validText(segment["speaker"], maxBytes: 128)))
            if segment["startMs"] is NSNull && segment["endMs"] is NSNull { continue }
            guard let start = Self.integer(segment["startMs"]), let finish = Self.integer(segment["endMs"]) else { try BatchValidation.require(false); return }
            try BatchValidation.require(start >= 0 && start < finish && finish <= end)
        }
        try Self.rejectDuplicateKeys(bytes)
    }
    private static func exact(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else { try BatchValidation.require(false); return [:] }
        return object
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, abs(d) <= Double(BatchValidation.safeInteger), d.rounded(.towardZero) == d else { return nil }
        return Int64(d)
    }
    // Same ECMAScript trim + Unicode Cf/content policy as chunkResults.ts.
    // Validation only: do not trim, normalize or reserialize the retained rawText.
    static func validText(_ value: Any?, maxBytes: Int) -> Bool {
        guard let text = value as? String, text.utf8.count <= maxBytes else { return false }
        var content = false
        for scalar in text.unicodeScalars {
            let c = scalar.value
            if c <= 8 || c == 11 || c == 12 || (14...31).contains(c) || (127...159).contains(c) || c == 0x061c || c == 0x200e || c == 0x200f || (0x202a...0x202e).contains(c) || (0x2066...0x2069).contains(c) { return false }
            let whitespace = (9...13).contains(c) || c == 32 || c == 0xa0 || c == 0x1680 || (0x2000...0x200a).contains(c) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000 || c == 0xfeff
            if !whitespace && scalar.properties.generalCategory != .format { content = true }
        }
        return content
    }
    // Foundation establishes JSON syntax/shape first. Scan strings to reject duplicate
    // decoded keys (including escaped aliases), and malformed surrogate escapes.
    // Two object levels maximum, including values hidden by duplicate-key semantics.
    private static func rejectDuplicateKeys(_ data: Data) throws {
        let bytes = Array(data)
        var objects: [Set<String>] = [], i = 0
        while i < bytes.count {
            // Foundation permits trailing commas; JSON.parse/server contract does not.
            if bytes[i] == 44 {
                var after = i + 1
                while after < bytes.count && [9, 10, 13, 32].contains(bytes[after]) { after += 1 }
                try BatchValidation.require(after < bytes.count && bytes[after] != 125 && bytes[after] != 93)
            }
            else if bytes[i] == 123 { try BatchValidation.require(objects.count < 2); objects.append([]) }
            else if bytes[i] == 125 { try BatchValidation.require(!objects.isEmpty); objects.removeLast() }
            else if bytes[i] == 34 {
                let start = i; i += 1
                while i < bytes.count && bytes[i] != 34 { if bytes[i] == 92 { i += 1 }; i += 1 }
                try BatchValidation.require(i < bytes.count)
                let string = try JSONDecoder().decode(String.self, from: Data(bytes[start...i]))
                var after = i + 1
                while after < bytes.count && [9, 10, 13, 32].contains(bytes[after]) { after += 1 }
                if after < bytes.count && bytes[after] == 58 {
                    try BatchValidation.require(!objects.isEmpty)
                    try BatchValidation.require(objects[objects.count - 1].insert(string).inserted)
                }
            }
            i += 1
        }
    }
}
struct BatchAggregate: Codable, Equatable {
    struct Source: Codable, Equatable {
        struct Speaker: Codable, Equatable { let chunkIndex: Int; let localLabel: String }
        let chunkIndex: Int; let segmentIndex: Int; let speaker: Speaker?
    }
    struct Timed: Codable, Equatable { let startMs: Int64; let endMs: Int64; let text: String; let sources: [Source]; let overlaps: Bool }
    struct Untimed: Codable, Equatable {
        struct Segment: Codable, Equatable { let text: String; let source: Source }
        let chunkIndex: Int; let segments: [Segment]
    }
    let version: Int; let durationMs: Int64; let missingChunks: [Int]; let timed: [Timed]; let untimed: [Untimed]
}
struct BatchAggregateResponse: Codable, Equatable {
    let version: Int; let batchId: String; let revision: Int64; let status: String
    let missingChunks: [Int]; let aggregate: BatchAggregate?
    func validate(manifest: BatchManifest) throws {
        let windows = try TranscriptionChunks.windows(duration: manifest.source.duration.time)
        try BatchValidation.require(version == 1 && revision >= 0 && revision <= BatchValidation.safeInteger)
        try BatchValidation.require(["pending", "complete", "partial", "too_large"].contains(status))
        try BatchValidation.require((status == "complete" || status == "partial") == (aggregate != nil))
        try BatchValidation.require(missingChunks == Array(Set(missingChunks)).sorted() && missingChunks.allSatisfy { windows.indices.contains($0) })
        try BatchValidation.require(status != "complete" || missingChunks.isEmpty)
        try BatchValidation.require(status != "partial" || !missingChunks.isEmpty)
        if let aggregate {
            try BatchValidation.require(aggregate.version == 1 && aggregate.durationMs == manifest.source.duration.enclosingMilliseconds && aggregate.missingChunks == missingChunks)
            for segment in aggregate.timed {
                try BatchValidation.require(segment.startMs >= 0 && segment.startMs < segment.endMs && segment.endMs <= aggregate.durationMs && !segment.sources.isEmpty && segment.text.utf8.count <= 8192)
                for source in segment.sources {
                    try validateSource(source, windows: windows)
                    let duration = windows[source.chunkIndex].range.duration
                    let start = Int64(source.chunkIndex) * 295_000
                    let end = start + (try BatchValidation.multiply(duration.value, 1000)) / Int64(duration.timescale)
                    try BatchValidation.require(segment.startMs >= start && segment.endMs <= end)
                }
            }
            for section in aggregate.untimed {
                try BatchValidation.require(windows.indices.contains(section.chunkIndex) && !missingChunks.contains(section.chunkIndex))
                for segment in section.segments {
                    try validateSource(segment.source, windows: windows)
                    try BatchValidation.require(segment.source.chunkIndex == section.chunkIndex && segment.text.utf8.count <= 8192)
                }
            }
        }
    }
    private func validateSource(_ source: BatchAggregate.Source, windows: [TranscriptionChunks.Window]) throws {
        try BatchValidation.require(windows.indices.contains(source.chunkIndex) && !missingChunks.contains(source.chunkIndex) && (0..<2048).contains(source.segmentIndex))
        if let speaker = source.speaker { try BatchValidation.require(speaker.chunkIndex == source.chunkIndex && speaker.localLabel.utf8.count <= 128) }
    }
}

/// Optional per-recording cache; never reinterpret legacy cloud IDs as batch IDs.
struct LocalBatch: Codable, Equatable {
    struct Pending: Codable, Equatable {
        let kind: String; var index: Int? = nil; var expectedAttempt: Int? = nil
        var expectedFence: Int64? = nil; var requestId: String? = nil
    }
    let clientBatchId: String
    let manifest: BatchManifest
    let chunkPaths: [String]
    var status: BatchStatus?
    var pending: Pending?
    var aggregate: BatchAggregateResponse?
    var lastReadableAggregate: BatchAggregateResponse?
    var results: [String: BatchRawResult] = [:]
    var notice: String?
    var chat: LocalBatchChat?
}
