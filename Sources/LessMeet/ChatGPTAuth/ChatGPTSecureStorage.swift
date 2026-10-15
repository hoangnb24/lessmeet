import Foundation
import Security

@MainActor
final class ChatGPTKeychainStore: ChatGPTCredentialStore {
    private let service: String

    init(service: String = "com.lessmeet.chatgpt.auth.v1") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "host-and-sessions",
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ChatGPTAuthError.storage }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ChatGPTAuthError.storage }
        } else if status != errSecSuccess {
            throw ChatGPTAuthError.storage
        }
    }
}

/// The lock contains no credentials. The kernel releases it when a process exits.
@MainActor
final class ChatGPTFileLock: ChatGPTCredentialLock {
    private let directory: URL
    private var descriptor: Int32 = -1

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LessMeet/ChatGPTAuth", isDirectory: true)
    }

    func acquire() async throws {
        let deadline = Date().addingTimeInterval(10)
        while descriptor != -1 {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ChatGPTAuthError.locked }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatGPTAuthError.storage }
        var acquired = false
        defer { if !acquired { close(fd) } }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw ChatGPTAuthError.storage }
            try Task.checkCancellation()
            guard Date() < deadline else { throw ChatGPTAuthError.locked }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try Task.checkCancellation()
        descriptor = fd
        acquired = true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
