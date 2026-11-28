import Foundation

/// One provider's OAuth 2.0 public-client settings. No client secret: both providers use PKCE.
/// See docs/REMOTE_SOURCES.md#authentication-dropbox--onedrive.
public struct OAuthConfiguration: Sendable {
    public enum Revocation: Sendable {
        /// The provider has no revoke endpoint (Microsoft consumer accounts); tokens are only deleted locally.
        case none
        /// POST to this URL with the access token as a bearer token (Dropbox `/2/auth/token/revoke`).
        case bearerPost(URL)
    }

    public var authorizeURL: URL
    public var tokenURL: URL
    public var clientId: String
    public var redirectURI: URL
    public var scopes: [String]
    /// Extra query items for the authorisation URL, such as Dropbox's `token_access_type=offline`.
    public var extraAuthorizeParameters: [String: String]
    public var revocation: Revocation

    public init(
        authorizeURL: URL,
        tokenURL: URL,
        clientId: String,
        redirectURI: URL,
        scopes: [String],
        extraAuthorizeParameters: [String: String] = [:],
        revocation: Revocation = .none
    ) {
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.extraAuthorizeParameters = extraAuthorizeParameters
        self.revocation = revocation
    }

    /// The custom URL scheme the system browser returns to, such as `db-<appkey>`.
    public var callbackScheme: String {
        redirectURI.scheme ?? ""
    }
}
