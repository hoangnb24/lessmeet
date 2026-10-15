import Foundation
import CryptoKit
import Darwin

enum ModelDownloadError: LocalizedError {
    case invalidCatalog, unsafePath, busy, io, response, length, integrity(String)

    var errorDescription: String? {
        switch self {
        case .invalidCatalog: return "The pinned model catalog is invalid."
        case .unsafePath: return "The model folder contains an unsafe path or link."
        case .busy: return "Another model check or download is running. Try again when it finishes."
        case .io: return "Cannot read or write the model folder. Check permissions and free disk space."
        case .response: return "The model server returned an invalid response. Retry to resume."
        case .length: return "The model transfer has the wrong byte count. Retry to resume."
        case .integrity(let path): return "Integrity check failed for \(path). Retry downloads a clean copy."
        }
    }
}

// All filesystem work runs off MainActor. Directory-relative descriptors prevent
// symlink traversal, including a path component replaced during an operation.
final class ModelDownloadStore: @unchecked Sendable {
    struct Entry: Sendable {
        let artifact: LocalModelArtifact
        let file: LocalModelFile
        var path: String { artifact.directory + "/" + file.path }
        var part: String { ".partial/" + file.sha256 + ".part" }
        var url: URL {
            URL(string: "https://huggingface.co/\(artifact.repository)/resolve/\(artifact.revision)/\(file.path)")!
        }
    }

    let root: URL
    let entries: [Entry]
    let totalBytes: Int64
    private let configuration: URLSessionConfiguration

    init(root: URL, catalog: [LocalModelArtifact], configuration: URLSessionConfiguration) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !catalog.isEmpty else {
            throw ModelDownloadError.invalidCatalog
        }
        var names = Set<String>()
        var ids = Set<String>()
        var paths = Set<String>()
        var total: Int64 = 0
        var entries: [Entry] = []
        for artifact in catalog {
            guard Self.safe(artifact.directory), !artifact.directory.contains("/"),
                  !artifact.directory.hasPrefix("."), names.insert(artifact.directory.lowercased()).inserted,
                  ids.insert(artifact.id).inserted, !artifact.files.isEmpty,
                  Self.safe(artifact.repository), artifact.repository.split(separator: "/").count == 2,
                  Self.hex(artifact.revision, count: 40) else { throw ModelDownloadError.invalidCatalog }
            for file in artifact.files {
                let entry = Entry(artifact: artifact, file: file)
                guard Self.safe(file.path), file.bytes > 0, Self.hex(file.sha256, count: 64),
                      paths.insert(entry.path.lowercased()).inserted else { throw ModelDownloadError.invalidCatalog }
                let sum = total.addingReportingOverflow(file.bytes)
                guard !sum.overflow else { throw ModelDownloadError.invalidCatalog }
                total = sum.partialValue
                entries.append(entry)
            }
        }
        // Reject file/directory collisions before touching disk.
        for path in paths {
            var parts = path.split(separator: "/")
            parts.removeLast()
            while !parts.isEmpty {
                guard !paths.contains(parts.joined(separator: "/")) else { throw ModelDownloadError.invalidCatalog }
                parts.removeLast()
            }
        }
        guard ids == Set(["whisper-large-v3", "whisper-tokenizer", "nemotron3-int8"]),
              catalog.first(where: { $0.id == "whisper-large-v3" })!.files.allSatisfy({
                  $0.path.hasPrefix("openai_whisper-large-v3/")
              }) else { throw ModelDownloadError.invalidCatalog }
        self.root = root
        self.entries = entries
        self.totalBytes = total
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    private static func hex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func safe(_ text: String) -> Bool {
        text.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." &&
            $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
        } && !text.isEmpty
    }

    func run(download: Bool, progress: @escaping @Sendable (Int64, String) -> Void) async throws -> InstalledLocalModels? {
        try Task.checkCancellation()
        let tree = try ModelTree(root: root)
        defer { tree.closeTree() }
        var completed: Int64 = 0
        var allVerified = true
        for entry in entries {
            try Task.checkCancellation()
            progress(completed, entry.path)
            if try tree.verified(entry.path, file: entry.file) {
                completed += entry.file.bytes
                progress(completed, entry.path)
                continue
            }
            guard download else { allVerified = false; continue }
            let fd = try tree.openFile(entry.part, create: true)
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw ModelDownloadError.io }
            var offset = info.st_size
            if offset > entry.file.bytes {
                guard ftruncate(fd, 0) == 0 else { throw ModelDownloadError.io }
                offset = 0
            }
            if offset < entry.file.bytes {
                let base = completed
                let transfer = ModelTransfer(fd: fd, expected: entry.file.bytes, offset: offset,
                                             configuration: configuration) { bytes in
                    progress(base + bytes, entry.path)
                }
                try await transfer.fetch(entry.url)
            }
            try Task.checkCancellation()
            guard try tree.verifiedDescriptor(fd, file: entry.file) else {
                // Only truncate this catalog-owned staging file. Keep installed files intact.
                guard ftruncate(fd, 0) == 0 else { throw ModelDownloadError.io }
                throw ModelDownloadError.integrity(entry.path)
            }
            guard fsync(fd) == 0 else { throw ModelDownloadError.io }
            try Task.checkCancellation()
            try tree.publish(part: entry.part, descriptor: fd, destination: entry.path)
            completed += entry.file.bytes
            progress(completed, entry.path)
        }
        try Task.checkCancellation()
        guard allVerified else { return nil }
        func folder(_ id: String) -> URL {
            root.appendingPathComponent(entries.first(where: { $0.artifact.id == id })!.artifact.directory)
        }
        return InstalledLocalModels(
            whisperDirectory: folder("whisper-large-v3").appendingPathComponent("openai_whisper-large-v3"),
            tokenizerDirectory: folder("whisper-tokenizer"), diarizerDirectory: folder("nemotron3-int8"))
    }
}

private final class ModelTree {
    private let rootFD: Int32
    private let lockFD: Int32

    init(root: URL) throws {
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ModelDownloadError.io }
        do {
            let components = root.path.split(separator: "/")
            guard !components.isEmpty else { throw ModelDownloadError.unsafePath }
            for component in components {
                guard component != ".", component != ".." else { throw ModelDownloadError.unsafePath }
                let name = String(component)
                if mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw ModelDownloadError.io }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ModelDownloadError.unsafePath }
                Darwin.close(fd)
                fd = next
            }
            let lock = openat(fd, ".download-lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw ModelDownloadError.unsafePath }
            var info = stat()
            guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
                Darwin.close(lock)
                throw ModelDownloadError.unsafePath
            }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(lock)
                throw ModelDownloadError.busy
            }
            rootFD = fd
            lockFD = lock
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func closeTree() { Darwin.close(lockFD); Darwin.close(rootFD) }

    private func parent(_ path: String, create: Bool) throws -> (Int32, String)? {
        var parts = path.split(separator: "/").map(String.init)
        let leaf = parts.removeLast()
        var fd = dup(rootFD)
        guard fd >= 0 else { throw ModelDownloadError.io }
        do {
            for part in parts {
                if create, mkdirat(fd, part, 0o700) != 0 && errno != EEXIST { throw ModelDownloadError.io }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    if !create && errno == ENOENT { Darwin.close(fd); return nil }
                    throw ModelDownloadError.unsafePath
                }
                Darwin.close(fd)
                fd = next
            }
            return (fd, leaf)
        } catch { Darwin.close(fd); throw error }
    }

    func openFile(_ path: String, create: Bool) throws -> Int32 {
        guard let (parent, name) = try parent(path, create: create) else { return -1 }
        defer { Darwin.close(parent) }
        let flags = (create ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let fd = openat(parent, name, flags, 0o600)
        if fd < 0 {
            if !create && errno == ENOENT { return -1 }
            throw ModelDownloadError.unsafePath
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd)
            throw ModelDownloadError.unsafePath
        }
        return fd
    }

    func verified(_ path: String, file: LocalModelFile) throws -> Bool {
        let fd = try openFile(path, create: false)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return try verifiedDescriptor(fd, file: file)
    }

    func verifiedDescriptor(_ fd: Int32, file: LocalModelFile) throws -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ModelDownloadError.io }
        guard info.st_size == file.bytes else { return false }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw ModelDownloadError.io }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let read = Darwin.read(fd, &buffer, buffer.count)
            if read < 0 { if errno == EINTR { continue }; throw ModelDownloadError.io }
            if read == 0 { break }
            count += Int64(read)
            guard count <= file.bytes else { return false }
            hash.update(data: Data(buffer.prefix(read)))
        }
        return count == file.bytes && hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }

    func publish(part: String, descriptor: Int32, destination: String) throws {
        guard let (source, sourceName) = try parent(part, create: false) else { throw ModelDownloadError.io }
        defer { Darwin.close(source) }
        guard let (target, targetName) = try parent(destination, create: true) else { throw ModelDownloadError.io }
        defer { Darwin.close(target) }
        var verified = stat()
        var staging = stat()
        guard fstat(descriptor, &verified) == 0,
              fstatat(source, sourceName, &staging, AT_SYMLINK_NOFOLLOW) == 0,
              (staging.st_mode & S_IFMT) == S_IFREG, staging.st_nlink == 1,
              staging.st_dev == verified.st_dev, staging.st_ino == verified.st_ino else {
            throw ModelDownloadError.unsafePath
        }
        // Refuse a pre-existing symlink, directory or hard link at the destination.
        let existing = try openFile(destination, create: false)
        if existing >= 0 { Darwin.close(existing) }
        guard renameat(source, sourceName, target, targetName) == 0, fsync(target) == 0 else {
            throw ModelDownloadError.io
        }
    }
}

// URLSession delivers bounded chunks on this serial delegate queue. No payload
// accumulates in memory, and neither network writes nor hashing use MainActor.
private final class ModelTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let fd: Int32
    let expected: Int64
    var received: Int64
    let initialOffset: Int64
    let configuration: URLSessionConfiguration
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var accepted = false
    private var lastProgress = Date.distantPast

    init(fd: Int32, expected: Int64, offset: Int64, configuration: URLSessionConfiguration,
         progress: @escaping @Sendable (Int64) -> Void) {
        self.fd = fd; self.expected = expected; self.received = offset; self.initialOffset = offset
        self.configuration = configuration; self.progress = progress
    }

    func fetch(_ url: URL) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                defer { lock.unlock() }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = configuration.copy() as! URLSessionConfiguration
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.httpAdditionalHeaders = [:]
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if initialOffset > 0 { request.setValue("bytes=\(initialOffset)-", forHTTPHeaderField: "Range") }
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        task?.cancel()
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Signed Hugging Face CDN redirects are allowed, but never downgrade TLS
        // or accept URL credentials. The final bytes still need the pinned hash.
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else {
            failure = ModelDownloadError.response
            completionHandler(nil)
            return
        }
        var clean = request
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if initialOffset > 0 { clean.setValue("bytes=\(initialOffset)-", forHTTPHeaderField: "Range") }
        completionHandler(clean)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse,
                  http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true
            else { throw ModelDownloadError.response }
            let length: Int64
            if http.statusCode == 206 {
                guard http.value(forHTTPHeaderField: "Content-Range") == "bytes \(initialOffset)-\(expected - 1)/\(expected)"
                else { throw ModelDownloadError.response }
                length = expected - initialOffset
            } else if http.statusCode == 200 {
                guard http.value(forHTTPHeaderField: "Content-Range") == nil else { throw ModelDownloadError.response }
                length = expected
            } else { throw ModelDownloadError.response }
            if let declared = http.value(forHTTPHeaderField: "Content-Length") {
                guard Int64(declared) == length else { throw ModelDownloadError.length }
            }
            if http.statusCode == 200 && initialOffset > 0 {
                guard ftruncate(fd, 0) == 0 else { throw ModelDownloadError.io }
                received = 0
            }
            guard lseek(fd, received, SEEK_SET) == received else { throw ModelDownloadError.io }
            accepted = true
            progress(received)
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, accepted else { return }
        guard Int64(data.count) <= expected - received else {
            failure = ModelDownloadError.length
            dataTask.cancel()
            return
        }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < data.count {
                    let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw ModelDownloadError.io }
                    offset += written
                }
            }
            received += Int64(data.count)
            let now = Date()
            if received == expected || now.timeIntervalSince(lastProgress) >= 0.1 {
                lastProgress = now
                progress(received)
            }
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancelled
        self.task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { continuation?.resume(throwing: error) }
        else if !accepted || received != expected { continuation?.resume(throwing: ModelDownloadError.length) }
        else { continuation?.resume() }
    }
}
