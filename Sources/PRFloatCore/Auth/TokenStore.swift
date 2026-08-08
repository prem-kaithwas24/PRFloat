import Foundation
import Security

public enum TokenStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(detail)"
        }
    }
}

/// Storage seam for the GitHub access token. Tests use `InMemoryTokenStore`.
public protocol TokenStore: Sendable {
    /// The stored token, or nil when signed out.
    func read() throws -> StoredToken?
    func write(_ token: StoredToken) throws
    func delete() throws
}

public struct StoredToken: Equatable, Sendable {
    public let token: String
    public let login: String

    public init(token: String, login: String) {
        self.token = token
        self.login = login
    }
}

/// Keychain-backed token storage.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlock` because the app polls in the background and
/// may need the token before the user has interacted with the session.
public struct KeychainTokenStore: TokenStore {
    private let service: String

    public init(service: String = "com.prfloat.github") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
    }

    public func read() throws -> StoredToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }

        guard
            let dict = item as? [String: Any],
            let data = dict[kSecValueData as String] as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let login = dict[kSecAttrAccount as String] as? String ?? ""
        return StoredToken(token: token, login: login)
    }

    public func write(_ token: StoredToken) throws {
        try delete()

        var query = baseQuery
        query[kSecAttrAccount as String] = token.login
        query[kSecValueData as String] = Data(token.token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}

/// Test double; also used when the Keychain is unavailable in a sandboxed preview.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StoredToken?

    public init(stored: StoredToken? = nil) {
        self.stored = stored
    }

    public func read() throws -> StoredToken? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func write(_ token: StoredToken) throws {
        lock.lock(); defer { lock.unlock() }
        stored = token
    }

    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
