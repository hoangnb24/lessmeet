import Foundation

struct LocalTranscript: Codable, Equatable {
    var version: Int = 1
    var segments: [LocalTranscriptSegment]

    init(version: Int = 1, segments: [LocalTranscriptSegment]) {
        self.version = version
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey { case version, segments }

    init(from decoder: Decoder) throws {
        try requireLocalTranscriptKeys(decoder, ["version", "segments"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        segments = try container.decode([LocalTranscriptSegment].self, forKey: .segments)
        try validate()
    }

    func validate() throws {
        guard version == 1 else { throw LocalTranscriptError.unsupportedVersion(version) }
        for segment in segments { try segment.validate() }
    }
}

struct LocalTranscriptSegment: Codable, Equatable {
    var startMs: Int64?
    var endMs: Int64?
    var speaker: String?
    var text: String

    init(startMs: Int64?, endMs: Int64?, speaker: String?, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case startMs, endMs, speaker, text }

    init(from decoder: Decoder) throws {
        try requireLocalTranscriptKeys(decoder, ["startMs", "endMs", "speaker", "text"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startMs = try container.decodeIfPresent(Int64.self, forKey: .startMs)
        endMs = try container.decodeIfPresent(Int64.self, forKey: .endMs)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        text = try container.decode(String.self, forKey: .text)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startMs, forKey: .startMs)
        try container.encode(endMs, forKey: .endMs)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(text, forKey: .text)
    }

    func validate() throws {
        switch (startMs, endMs) {
        case (nil, nil): break
        case let (start?, end?) where start >= 0 && start < end: break
        default: throw LocalTranscriptError.invalidTimestamps
        }
    }
}

enum LocalTranscriptError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidTimestamps
    case invalidKeys
    case malformedJSON
    case tooLarge
}

private struct LocalTranscriptKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireLocalTranscriptKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let container = try decoder.container(keyedBy: LocalTranscriptKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == expected else {
        throw LocalTranscriptError.invalidKeys
    }
}
