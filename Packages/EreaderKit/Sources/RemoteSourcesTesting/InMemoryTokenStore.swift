import Foundation
import RemoteSources

/// A `TokenStore` for tests: keeps tokens in memory instead of the Keychain.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    // Guarded by `lock`.
    private var storage: [String: OAuthTokens] = [:]
    private let lock = NSLock()

    public init() {}

    public func tokens(forSource sourceId: String) throws -> OAuthTokens? {
        lock.withLock { storage[sourceId] }
    }

    public func save(_ tokens: OAuthTokens, forSource sourceId: String) throws {
        lock.withLock { storage[sourceId] = tokens }
    }

    public func deleteTokens(forSource sourceId: String) throws {
        lock.withLock { _ = storage.removeValue(forKey: sourceId) }
    }
}
