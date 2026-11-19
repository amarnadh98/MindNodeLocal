import Foundation
import Security

/// Where provider API keys live (SPEC §12: Keychain, never in
/// documents or logs). A protocol so tests (and any future in-memory
/// host) inject a double; `SystemKeychainStore` is the real
/// Security-framework implementation.
public protocol APIKeyStore: Sendable {
    /// Stores `key` for `account`, overwriting any previous value.
    func save(_ key: String, account: String) throws
    /// The stored key, or nil when none exists.
    func load(account: String) -> String?
    /// Removes the stored key; removing a missing key is not an error.
    func delete(account: String) throws
}

/// Keychain accounts used by the AI providers. Constants, not stringly
/// scattered.
public enum APIKeyAccount {
    public static let anthropic = "arbor.anthropic-api-key"
    public static let openAICompatible = "arbor.openai-compatible-api-key"
}

/// The in-memory test double: never touches the system Keychain, so
/// `swift test` needs no entitlements and no signing.
public final class InMemoryKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    public init() {}

    public func save(_ key: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        keys[account] = key
    }

    public func load(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[account]
    }

    public func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        keys.removeValue(forKey: account)
    }
}

/// Generic-password Keychain wrapper over the Security framework. The
/// key only ever travels between the Keychain and request headers —
/// it is never logged, echoed, or written to a document (SPEC §12).
public struct SystemKeychainStore: APIKeyStore {
    public let service: String

    public init(service: String = "com.arbor.ai") {
        self.service = service
    }

    public func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        // Update when a value exists, add when none does.
        var query = baseQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecClass as String] = kSecClassGenericPassword
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AIError.invalidResponse("Keychain write failed (\(addStatus))")
            }
        } else if status != errSecSuccess {
            throw AIError.invalidResponse("Keychain update failed (\(status))")
        }
    }

    public func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIError.invalidResponse("Keychain delete failed (\(status))")
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
