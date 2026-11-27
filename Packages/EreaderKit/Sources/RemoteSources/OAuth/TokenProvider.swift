import Foundation

/// Hands out a valid access token for one linked source, refreshing it when it is within
/// `OAuthTokens.refreshMargin` of expiry. Concurrent callers share a single refresh.
///
/// A refresh the provider rejects (revoked or expired grant) becomes `RemoteSourceError.needsRelink`, so the
/// source is marked for re-linking. Network errors are passed through unchanged, so a retry can succeed.
public actor TokenProvider {
    private let client: OAuthClient
    private let store: any TokenStore
    private let sourceId: String
    private var refreshTask: Task<OAuthTokens, any Error>?

    public init(client: OAuthClient, store: any TokenStore, sourceId: String) {
        self.client = client
        self.store = store
        self.sourceId = sourceId
    }

    /// Saves the tokens from a completed sign-in.
    public func signedIn(with tokens: OAuthTokens) throws {
        try store.save(tokens, forSource: sourceId)
    }

    /// An access token good for at least `refreshMargin`.
    public func validAccessToken() async throws -> String {
        let tokens = try storedTokens()
        guard tokens.needsRefresh(at: client.now()) else { return tokens.accessToken }
        return try await refreshed(tokens).accessToken
    }

    /// After a `401`: refresh once regardless of the expiry date. A second `401` should mark the source
    /// for re-linking.
    public func forceRefresh() async throws -> String {
        try await refreshed(try storedTokens()).accessToken
    }

    /// Revokes server-side where supported (best effort), then deletes the tokens from the store.
    public func signOut() async throws {
        if let tokens = try store.tokens(forSource: sourceId) {
            try? await client.revoke(tokens)
        }
        try store.deleteTokens(forSource: sourceId)
    }

    private func storedTokens() throws -> OAuthTokens {
        guard let tokens = try store.tokens(forSource: sourceId) else { throw RemoteSourceError.needsRelink }
        return tokens
    }

    private func refreshed(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value }
        let task = Task<OAuthTokens, any Error> { [client, store, sourceId] in
            do {
                let fresh = try await client.refresh(tokens)
                try store.save(fresh, forSource: sourceId)
                return fresh
            } catch let error as OAuthError {
                if Self.isRejectedGrant(error) { throw RemoteSourceError.needsRelink }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// 400 / 401 from the token endpoint (`invalid_grant`, `invalid_client`, …) or no refresh token at all.
    private static func isRejectedGrant(_ error: OAuthError) -> Bool {
        guard case .tokenRequestFailed(let status, _) = error else { return false }
        return status == 0 || status == 400 || status == 401
    }
}
