import Foundation

/// An access token and (usually) a refresh token. Stored only in the Keychain via `TokenStore`.
///
/// `description` is redacted so a token can't end up in a log or crash report by accident.
public struct OAuthTokens: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Refresh this long before expiry, so a request never goes out with a token about to lapse.
    public static let refreshMargin: TimeInterval = 5 * 60

    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True when the access token expires within `refreshMargin` of `now`. Tokens without an expiry never do.
    public func needsRefresh(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < Self.refreshMargin
    }

    public var description: String {
        "OAuthTokens(redacted, expiresAt: \(expiresAt.map(String.init(describing:)) ?? "none"))"
    }

    public var debugDescription: String { description }
}

/// The JSON body of a token response (RFC 6749 §5.1).
struct TokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    /// Tokens from this response. A refresh response may omit the refresh token, in which case the old one
    /// stays valid and is kept.
    func tokens(issuedAt now: Date, keeping previousRefreshToken: String? = nil) -> OAuthTokens {
        OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken ?? previousRefreshToken,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) }
        )
    }
}

/// The JSON body of a token error (RFC 6749 §5.2).
struct TokenErrorResponse: Decodable {
    var error: String
}

public enum OAuthError: Error, Equatable, Sendable {
    /// The callback's `state` didn't match the request's: possibly a forged redirect. The code is discarded.
    case stateMismatch
    /// The callback had neither a code nor an error.
    case missingCode
    /// The user (or an administrator's policy) declined the requested permissions.
    case accessDenied
    /// The token endpoint returned an error, such as `invalid_grant`.
    case tokenRequestFailed(status: Int, error: String?)
    /// The token endpoint's response couldn't be read.
    case invalidResponse
}
