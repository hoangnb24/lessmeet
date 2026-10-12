import Foundation
import Network

@MainActor
final class ChatGPTLoopbackListener: ChatGPTCallbackListener {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var ready: CheckedContinuation<URL, Error>?
    private var pending: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var consumed = false
    private var redirectURI: URL?
    private var timer: Task<Void, Never>?
    private let timeoutNanoseconds: UInt64

    init(timeoutNanoseconds: UInt64 = 300_000_000_000) { self.timeoutNanoseconds = timeoutNanoseconds }

    func start() async throws -> URL {
        guard listener == nil, result == nil else { throw ChatGPTAuthError.callback }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        let server = try NWListener(using: parameters, on: .any)
        listener = server
        server.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.result == nil else { return }
                switch state {
                case .ready:
                    guard let port = server.port,
                          let uri = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") else {
                        self.finish(.failure(ChatGPTAuthError.callback)); return
                    }
                    self.redirectURI = uri
                    self.ready?.resume(returning: uri)
                    self.ready = nil
                case .failed: self.finish(.failure(ChatGPTAuthError.callback))
                case .cancelled: self.finish(.failure(ChatGPTAuthError.canceled))
                default: break
                }
            }
        }
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        timer = Task { [weak self, timeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            self?.finish(.failure(ChatGPTAuthError.timeout))
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                server.start(queue: .main)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func callback() async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !consumed else { throw ChatGPTAuthError.callback }
            consumed = true
            if let result { return try result.get() }
            guard pending == nil else { throw ChatGPTAuthError.callback }
            return try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cancel() { finish(.failure(ChatGPTAuthError.canceled)) }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        guard case .hostPort(let host, _) = connection.endpoint, host == NWEndpoint.Host("127.0.0.1") else {
            connection.cancel(); return
        }
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection, data: Data())
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, self.result == nil else { connection.cancel(); return }
                let bytes = data + (chunk ?? Data())
                guard bytes.count <= 16_384, error == nil else {
                    self.finish(.failure(ChatGPTAuthError.callback)); return
                }
                if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                    do {
                        guard let uri = self.redirectURI else { throw ChatGPTAuthError.callback }
                        let url = try Self.parseRequest(bytes, redirectURI: uri)
                        let body = "Return to LessMeet to finish sign-in."
                        let reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
                        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                        self.finish(.success(url), replying: connection)
                    } catch { self.finish(.failure(ChatGPTAuthError.callback)) }
                } else if complete { self.finish(.failure(ChatGPTAuthError.callback)) }
                else { self.receive(connection, data: bytes) }
            }
        }
    }

    static func parseRequest(_ data: Data, redirectURI: URL) throws -> URL {
        guard data.count <= 16_384, let request = String(data: data, encoding: .utf8),
              request.hasSuffix("\r\n\r\n") else { throw ChatGPTAuthError.callback }
        let lines = request.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/auth/callback?"), !first[1].contains("#") else { throw ChatGPTAuthError.callback }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw ChatGPTAuthError.callback }
            let name = String(line[..<colon]).lowercased()
            guard headers[name] == nil, !name.contains(" "), !name.contains("\t") else { throw ChatGPTAuthError.callback }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(redirectURI.port!)", headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0",
              let url = URL(string: "http://127.0.0.1:\(redirectURI.port!)" + first[1]) else {
            throw ChatGPTAuthError.callback
        }
        return url
    }

    private func finish(_ value: Result<URL, Error>, replying: NWConnection? = nil) {
        guard result == nil else { return }
        result = value
        if let ready { ready.resume(throwing: value.failure ?? ChatGPTAuthError.callback) }
        ready = nil
        pending?.resume(with: value)
        pending = nil
        timer?.cancel()
        timer = nil
        listener?.cancel()
        listener = nil
        for connection in connections where connection !== replying { connection.cancel() }
        connections.removeAll()
    }
}

private extension Result where Success == URL, Failure == Error {
    var failure: Error? { if case .failure(let error) = self { return error }; return nil }
}
