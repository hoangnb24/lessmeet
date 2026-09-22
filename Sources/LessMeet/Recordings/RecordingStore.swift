import Foundation

struct RecordingStore {
    let root: URL

    init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("LessMeet/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for id: UUID, name: String = "combined.m4a") -> URL {
        directory(for: id).appendingPathComponent(name)
    }

    func save(_ recording: Recording) throws {
        let folder = directory(for: recording.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: folder.appendingPathComponent("recording.json"), options: .atomic)
    }

    func load() throws -> [Recording] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try folders.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { folder in
            let data = try Data(contentsOf: folder.appendingPathComponent("recording.json"))
            var recording = try JSONDecoder().decode(Recording.self, from: data)
            if recording.status == .recording {
                recording.status = .interrupted
                recording.failure = "Recording was interrupted before it was finalized. Original audio is retained in its folder."
                try save(recording)
            }
            return recording
        }.sorted { $0.createdAt > $1.createdAt }
    }
}
