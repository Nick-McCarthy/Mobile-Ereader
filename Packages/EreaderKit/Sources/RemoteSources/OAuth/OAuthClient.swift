import Foundation

/// One sign-in attempt: the URL to open, plus the secrets needed to finish it.
public struct AuthorizationRequest: Sendable {
    public let url: URL
    /// Random value echoed back by the provider; the callback is rejected unless it matches.
    public let state: String
    public let pkce: PKCE
}

/// The provider-agnostic OAuth 2.0 authorisation-code flow with PKCE (RFC 6749, RFC 7636).
///
/// `signIn` opens the system browser sheet via `WebAuthenticator` (`ASWebAuthenticationSession`), so the app
/// never sees the user's password. All HTTP goes through `HTTPClient`.
public struct OAuthClient: Sendable {
    public let configuration: OAuthConfiguration
    let http: any HTTPClient
    let now: @Sendable () -> Date

    public init(
        configuration: OAuthConfiguration,
        http: any HTTPClient = URLSession.ephemeralClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.http = http
        self.now = now
    }

    /// Runs the whole flow: browser sign-in, callback check, and code exchange.
    public func signIn(using authenticator: any WebAuthenticator) async throws -> OAuthTokens {
        let request = try makeAuthorizationRequest()
        let callback = try await authenticator.authenticate(
            url: request.url,
            callbackScheme: configuration.callbackScheme
        )
        let code = try authorizationCode(from: callback, for: request)
        return try await exchange(code: code, for: request)
    }

    /// A new authorisation URL with a fresh `state` and PKCE pair.
    public func makeAuthorizationRequest() throws -> AuthorizationRequest {
        let pkce = try PKCE()
        let state = try OAuthRandom.base64URL(byteCount: 16)
        guard var components = URLComponents(url: configuration.authorizeURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidResponse
        }
        var items = [
            URLQueryItem(name: "client_id", value: configuration.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
        ]
        if !configuration.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")))
        }
        for (name, value) in configuration.extraAuthorizeParameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        let existing = components.queryItems ?? []
        components.queryItems = existing + items
        guard let url = components.url else { throw OAuthError.invalidResponse }
        return AuthorizationRequest(url: url, state: state, pkce: pkce)
    }

    /// The authorisation code from the redirect, after checking it belongs to `request`.
    public func authorizationCode(from callback: URL, for request: AuthorizationRequest) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        // Check state before anything else, including errors, so a forged redirect can't drive the flow.
        guard let state = value("state"), state == request.state else { throw OAuthError.stateMismatch }
        if let error = value("error") {
            if error == "access_denied" { throw OAuthError.accessDenied }
            throw OAuthError.authorizationFailed(error: error)
        }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError.missingCode }
        return code
    }

    /// Trades the authorisation code (and the PKCE verifier) for tokens.
    public func exchange(code: String, for request: AuthorizationRequest) async throws -> OAuthTokens {
        let response = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "client_id": configuration.clientId,
            "code_verifier": request.pkce.verifier,
        ])
        return response.tokens(issuedAt: now())
    }

    /// New tokens from the refresh token. Throws `OAuthError.tokenRequestFailed` (for example
    /// `invalid_grant`) when the grant has been revoked or expired; the caller then asks the user to re-link.
    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw OAuthError.noRefreshToken
        }
        let response = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientId,
        ])
        return response.tokens(issuedAt: now(), keeping: refreshToken)
    }

    /// Revokes the tokens server-side where the provider supports it. Failure is ignored by callers:
    /// the tokens are deleted locally either way.
    public func revoke(_ tokens: OAuthTokens) async throws {
        guard case .bearerPost(let url) = configuration.revocation else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw OAuthError.tokenRequestFailed(status: response.statusCode, error: nil)
        }
    }

    private func tokenRequest(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncoded(parameters).utf8)

        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            throw OAuthError.tokenRequestFailed(status: response.statusCode, error: error?.error)
        }
        guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw OAuthError.invalidResponse
        }
        return body
    }

    /// `application/x-www-form-urlencoded`, keys sorted so requests are deterministic in tests.
    static func formEncoded(_ parameters: [String: String]) -> String {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        let allowed = CharacterSet(charactersIn: unreserved)
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        }
        let pairs = parameters.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }
        return pairs.joined(separator: "&")
    }
}
