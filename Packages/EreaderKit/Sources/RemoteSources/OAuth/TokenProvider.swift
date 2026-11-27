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
    private var refreshTask: Task<RefreshResult, any Error>?
    /// Fresh tokens whose Keychain save failed. Used, and saved again, before anything stored, so a
    /// rotated refresh token isn't lost.
    private var unsavedTokens: OAuthTokens?

    private struct RefreshResult: Sendable {
        let tokens: OAuthTokens
        let saved: Bool
    }

    public init(client: OAuthClient, store: any TokenStore, sourceId: String) {
        self.client = client
        self.store = store
        self.sourceId = sourceId
    }

    /// Saves the tokens from a completed sign-in.
    public func signedIn(with tokens: OAuthTokens) throws {
        unsavedTokens = nil
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
    /// An unreadable item can't be revoked, but it is still deleted.
    public func signOut() async throws {
        let tokens = unsavedTokens ?? (try? store.tokens(forSource: sourceId))
        unsavedTokens = nil
        if let tokens {
            try? await client.revoke(tokens)
        }
        try store.deleteTokens(forSource: sourceId)
    }

    /// The current tokens. Missing or unreadable ones mean the source must be linked again.
    private func storedTokens() throws -> OAuthTokens {
        if let unsavedTokens {
            if (try? store.save(unsavedTokens, forSource: sourceId)) != nil { self.unsavedTokens = nil }
            return unsavedTokens
        }
        let tokens: OAuthTokens?
        do {
            tokens = try store.tokens(forSource: sourceId)
        } catch KeychainError.undecodableItem {
            throw RemoteSourceError.needsRelink
        }
        guard let tokens else { throw RemoteSourceError.needsRelink }
        return tokens
    }

    private func refreshed(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value.tokens }
        let task = Task<RefreshResult, any Error> { [client, store, sourceId] in
            do {
                let fresh = try await client.refresh(tokens)
                // A failed save mustn't lose the fresh tokens: the old refresh token may already be invalid.
                let saved = (try? store.save(fresh, forSource: sourceId)) != nil
                return RefreshResult(tokens: fresh, saved: saved)
            } catch let error as OAuthError {
                if Self.isRejectedGrant(error) { throw RemoteSourceError.needsRelink }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        let result = try await task.value
        if !result.saved { unsavedTokens = result.tokens }
        return result.tokens
    }

    /// 400 / 401 from the token endpoint (`invalid_grant`, `invalid_client`, …) or no refresh token at all.
    private static func isRejectedGrant(_ error: OAuthError) -> Bool {
        switch error {
        case .noRefreshToken:
            return true
        case .tokenRequestFailed(let status, _):
            return status == 400 || status == 401
        default:
            return false
        }
    }
}
