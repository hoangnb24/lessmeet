import Foundation

extension RecordingStore {
    // 16 MiB exceeds 25 five-minute windows at the existing 384 KiB/window bound.
    // Reject larger files; never truncate a full recording's transcript.
    static let localTranscriptMaximumBytes = 16 * 1024 * 1024

    func loadLocalTranscript(for id: UUID) throws -> LocalTranscript? {
        let url = directory(for: id).appendingPathComponent("transcript.json")
        let handle: FileHandle
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw LocalTranscriptError.malformedJSON
            }
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            // FileHandle can use Cocoa's fileNoSuchFile code for other open failures.
            // Only the underlying POSIX ENOENT establishes that the file is missing.
            let failure = error as NSError
            let cause = (failure.userInfo[NSUnderlyingErrorKey] as? NSError) ?? failure
            if cause.domain == NSPOSIXErrorDomain && cause.code == Int(POSIXErrorCode.ENOENT.rawValue) {
                return nil
            }
            throw error
        }
        defer { try? handle.close() }
        var data = Data()
        while let block = try handle.read(upToCount: min(64 * 1024, Self.localTranscriptMaximumBytes + 1 - data.count)),
              !block.isEmpty {
            data.append(block)
            guard data.count <= Self.localTranscriptMaximumBytes else { throw LocalTranscriptError.tooLarge }
        }
        // JSONDecoder discards duplicate keys. Check the raw boundary first.
        var check = LocalTranscriptJSONCheck(bytes: Array(data))
        try check.validate()
        return try JSONDecoder().decode(LocalTranscript.self, from: data)
    }

    // WS2 is the sole writer. This does not update recording.json or cloud caches.
    func saveLocalTranscript(_ transcript: LocalTranscript, for id: UUID) throws {
        try transcript.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transcript)
        guard data.count <= Self.localTranscriptMaximumBytes else { throw LocalTranscriptError.tooLarge }
        let folder = directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
    }
}

// Check JSON structure and decoded key identity before Codable sees the bytes.
// Codable then checks primitive types, exact fields, version and timestamp pairs.
private struct LocalTranscriptJSONCheck {
    let bytes: [UInt8]
    var index = 0

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw LocalTranscriptError.malformedJSON }
    }

    mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func string() throws -> String {
        whitespace()
        let start = index
        guard take(34) else { throw LocalTranscriptError.malformedJSON }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            if byte == 92 { index += 1 }
        }
        throw LocalTranscriptError.malformedJSON
    }

    mutating func value(depth: Int) throws {
        guard depth <= 8 else { throw LocalTranscriptError.malformedJSON }
        whitespace()
        guard index < bytes.count else { throw LocalTranscriptError.malformedJSON }
        if take(123) {
            var keys = Set<String>()
            if take(125) { return }
            repeat {
                guard keys.insert(try string()).inserted else { throw LocalTranscriptError.invalidKeys }
                guard take(58) else { throw LocalTranscriptError.malformedJSON }
                try value(depth: depth + 1)
                if take(125) { return }
                guard take(44) else { throw LocalTranscriptError.malformedJSON }
            } while true
        } else if take(91) {
            if take(93) { return }
            repeat {
                try value(depth: depth + 1)
                if take(93) { return }
                guard take(44) else { throw LocalTranscriptError.malformedJSON }
            } while true
        } else if bytes[index] == 34 {
            _ = try string()
        } else {
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw LocalTranscriptError.malformedJSON }
            // Foundation validates the primitive grammar without accepting containers.
            _ = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed)
        }
    }
}
