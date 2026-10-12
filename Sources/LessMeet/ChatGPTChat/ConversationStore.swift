import Darwin
import Foundation

struct LocalConversation: Codable, Equatable {
    var version: Int = 1
    var recordingID: UUID
    var messages: [ChatMessage] = []
}

struct ConversationStore {
    enum StoreError: Error, Equatable {
        case unsupportedVersion
        case recordingIDMismatch
        case incompletePairs
        case unsafePath
    }

    private let recordingStore: RecordingStore

    init(recordingStore: RecordingStore) {
        self.recordingStore = recordingStore
    }

    func load(for recordingID: UUID) throws -> LocalConversation {
        let folder = try openFolder(for: recordingID, create: false)
        guard let folder else { return LocalConversation(recordingID: recordingID) }
        defer { close(folder) }
        return try read(folder: folder, recordingID: recordingID)
            ?? LocalConversation(recordingID: recordingID)
    }

    func save(_ conversation: LocalConversation) throws {
        try validate(conversation, recordingID: conversation.recordingID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(conversation)
        guard let folder = try openFolder(for: conversation.recordingID, create: true) else {
            throw StoreError.unsafePath
        }
        defer { close(folder) }
        // Refuse to overwrite an invalid sidecar. Recovery is an explicit caller action.
        _ = try read(folder: folder, recordingID: conversation.recordingID)
        let temporaryName = ".chat-\(UUID().uuidString).tmp"
        let file = openat(folder, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posixError() }
        defer {
            close(file)
            unlinkat(folder, temporaryName, 0)
        }
        guard fchmod(file, 0o600) == 0 else { throw posixError() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw posixError() }
        guard renameat(folder, temporaryName, folder, "chat.json") == 0 else { throw posixError() }
    }

    private func validate(_ conversation: LocalConversation, recordingID: UUID) throws {
        guard conversation.version == 1 else { throw StoreError.unsupportedVersion }
        guard conversation.recordingID == recordingID else { throw StoreError.recordingIDMismatch }
        guard conversation.messages.count.isMultiple(of: 2),
              conversation.messages.enumerated().allSatisfy({ index, message in
                  message.role == (index.isMultiple(of: 2) ? .user : .assistant)
              }) else { throw StoreError.incompletePairs }
    }

    private func openFolder(for recordingID: UUID, create: Bool) throws -> Int32? {
        let root = open(recordingStore.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw posixError() }
        defer { close(root) }
        let name = recordingStore.directory(for: recordingID).lastPathComponent
        guard name == recordingID.uuidString else { throw StoreError.unsafePath }
        if create, mkdirat(root, name, 0o700) != 0, errno != EEXIST { throw posixError() }
        let folder = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0 {
            if !create, errno == ENOENT { return nil }
            throw posixError()
        }
        return folder
    }

    private func read(folder: Int32, recordingID: UUID) throws -> LocalConversation? {
        let file = openat(folder, "chat.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw StoreError.unsafePath }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let conversation = try JSONDecoder().decode(LocalConversation.self, from: data)
        try validate(conversation, recordingID: recordingID)
        return conversation
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
