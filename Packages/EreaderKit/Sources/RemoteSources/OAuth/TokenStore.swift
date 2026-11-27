import Core
import Foundation
import Security

/// Where a linked source's OAuth tokens live. The only real implementation is the Keychain:
/// tokens never go in UserDefaults, the database, files, or logs (docs/SECURITY_AND_APP_STORE.md).
public protocol TokenStore: Sendable {
    /// Nil when there are none. Throws `KeychainError.undecodableItem` when the stored item can't be read.
    func tokens(forSource sourceId: String) throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens, forSource sourceId: String) throws
    /// Deleting tokens that don't exist is not an error.
    func deleteTokens(forSource sourceId: String) throws
}

public enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    /// The item exists but isn't valid token JSON (damaged, or written by an incompatible version).
    case undecodableItem
}

/// One generic-password item per linked source: service `ereader.<kind>`, account = `library_source.id`,
/// readable after first unlock and never migrated to another device.
public struct KeychainTokenStore: TokenStore {
    public let service: String

    public init(kind: SourceKind) {
        self.service = "ereader.\(kind.rawValue)"
    }

    public func tokens(forSource sourceId: String) throws -> OAuthTokens? {
        var query = baseQuery(account: sourceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.unexpectedStatus(status) }
        guard let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else {
            throw KeychainError.undecodableItem
        }
        return tokens
    }

    public func save(_ tokens: OAuthTokens, forSource sourceId: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let query = baseQuery(account: sourceId)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(addQuery(account: sourceId, data: data) as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func deleteTokens(forSource sourceId: String) throws {
        let status = SecItemDelete(baseQuery(account: sourceId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Identifies the item. Uses the data-protection keychain (the iOS keychain, also on macOS).
    func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The full item for `SecItemAdd`, including its accessibility class.
    func addQuery(account: String, data: Data) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }
}
