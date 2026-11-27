import Foundation
import RemoteSourcesTesting
import Security
import Testing

@testable import RemoteSources

// MARK: - Test doubles

/// Answers requests from a queue and records what was sent. Never touches the network.
private actor FakeHTTP: HTTPClient {
    struct Reply {
        var status: Int
        var body: String
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        let url = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)
        return (Data(reply.body.utf8), response ?? HTTPURLResponse())
    }

    var requestCount: Int { requests.count }

    func formBody(at index: Int) -> [String: String] {
        let body = String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }
}

/// Holds every token request until `open()`, then answers each with a new access token that is already due
/// for refresh. So a second, unshared refresh always makes a second request, however the calls interleave.
private actor GatedTokenHTTP: HTTPClient {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let number = requestCount
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        let url = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        return (Data(tokenJSON(access: "a\(number + 1)", expiresIn: 0).utf8), response ?? HTTPURLResponse())
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// Counts reads, so a test can tell when a caller has looked at the stored tokens.
private final class ReadCountingTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private let base = InMemoryTokenStore()
    private var reads = 0

    var readCount: Int { lock.withLock { reads } }

    func tokens(forSource sourceId: String) throws -> OAuthTokens? {
        lock.withLock { reads += 1 }
        return try base.tokens(forSource: sourceId)
    }

    func save(_ tokens: OAuthTokens, forSource sourceId: String) throws {
        try base.save(tokens, forSource: sourceId)
    }

    func deleteTokens(forSource sourceId: String) throws {
        try base.deleteTokens(forSource: sourceId)
    }

    func storedSourceIds() throws -> [String] {
        try base.storedSourceIds()
    }
}

/// Returns a canned redirect, as if the user signed in.
private struct FakeAuthenticator: WebAuthenticator {
    var callback: @Sendable (URL) -> URL

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        callback(url)
    }
}

/// Test URLs are literals; an invalid one should fail loudly rather than be force-unwrapped.
private func testURL(_ string: String) -> URL {
    guard let url = URL(string: string) else { preconditionFailure("bad test URL \(string)") }
    return url
}

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

private let configuration = OAuthConfiguration(
    authorizeURL: testURL("https://auth.example.com/authorize"),
    tokenURL: testURL("https://auth.example.com/token"),
    clientId: "client-123",
    redirectURI: testURL("db-client-123://2/token"),
    scopes: ["files.metadata.read", "files.content.read"],
    extraAuthorizeParameters: ["token_access_type": "offline"],
    revocation: .bearerPost(testURL("https://api.example.com/2/auth/token/revoke"))
)

private func tokenJSON(access: String, refresh: String? = nil, expiresIn: Int = 14_400) -> String {
    let refreshField = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
    return #"{"access_token":"\#(access)","token_type":"bearer","expires_in":\#(expiresIn)\#(refreshField)}"#
}

private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

// MARK: - Tests

@Suite("OAuth with PKCE")
struct OAuthTests {
    @Test("PKCE matches the RFC 7636 example and generates fresh base64url verifiers")
    func pkce() throws {
        let example = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(example.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(example.method == "S256")

        let first = try PKCE()
        let second = try PKCE()
        #expect(first.verifier.count == 43)
        #expect(first.verifier != second.verifier)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(first.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    @Test("The authorisation URL carries the client, redirect, state, S256 challenge, scopes, and extras")
    func authorizationURL() throws {
        let client = OAuthClient(configuration: configuration, http: FakeHTTP([]))
        let request = try client.makeAuthorizationRequest()
        let items = query(request.url)

        #expect(request.url.host() == "auth.example.com")
        #expect(items["client_id"] == "client-123")
        #expect(items["response_type"] == "code")
        #expect(items["redirect_uri"] == "db-client-123://2/token")
        #expect(items["state"] == request.state)
        #expect(items["code_challenge"] == request.pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["scope"] == "files.metadata.read files.content.read")
        #expect(items["token_access_type"] == "offline")
        #expect(items["code_verifier"] == nil, "the verifier must not appear in the browser URL")
        #expect(try client.makeAuthorizationRequest().state != request.state)
    }

    @Test("Callbacks are rejected unless the state matches")
    func callbackValidation() throws {
        let client = OAuthClient(configuration: configuration, http: FakeHTTP([]))
        let request = try client.makeAuthorizationRequest()
        func callback(_ query: String) -> URL { testURL("db-client-123://2/token?\(query)") }

        #expect(try client.authorizationCode(from: callback("code=abc&state=\(request.state)"), for: request) == "abc")
        #expect(throws: OAuthError.stateMismatch) {
            _ = try client.authorizationCode(from: callback("code=abc&state=forged"), for: request)
        }
        #expect(throws: OAuthError.stateMismatch) {
            _ = try client.authorizationCode(from: callback("code=abc"), for: request)
        }
        #expect(throws: OAuthError.stateMismatch) {
            _ = try client.authorizationCode(from: callback("error=access_denied&state=forged"), for: request)
        }
        #expect(throws: OAuthError.accessDenied) {
            _ = try client.authorizationCode(from: callback("error=access_denied&state=\(request.state)"), for: request)
        }
        #expect(throws: OAuthError.missingCode) {
            _ = try client.authorizationCode(from: callback("state=\(request.state)"), for: request)
        }
    }

    @Test("Sign-in exchanges the code with the PKCE verifier and computes the expiry")
    func signIn() async throws {
        let http = FakeHTTP([.init(status: 200, body: tokenJSON(access: "access-1", refresh: "refresh-1"))])
        let client = OAuthClient(configuration: configuration, http: http, now: { fixedNow })
        let authenticator = FakeAuthenticator { url in
            testURL("db-client-123://2/token?code=the-code&state=\(query(url)["state"] ?? "")")
        }

        let tokens = try await client.signIn(using: authenticator)
        #expect(tokens == OAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: fixedNow + 14_400))

        let sent = await http.requests
        #expect(sent.first?.url == configuration.tokenURL)
        #expect(sent.first?.httpMethod == "POST")
        let form = await http.formBody(at: 0)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "the-code")
        #expect(form["client_id"] == "client-123")
        #expect(form["redirect_uri"] == "db-client-123://2/token")
        #expect(form["code_verifier"]?.count == 43)
        #expect(form["client_secret"] == nil, "public clients never send a secret")
    }

    @Test("Refresh keeps the old refresh token when the response omits it, and reports rejected grants")
    func refresh() async throws {
        let http = FakeHTTP([
            .init(status: 200, body: tokenJSON(access: "access-2")),
            .init(status: 400, body: #"{"error":"invalid_grant"}"#),
        ])
        let client = OAuthClient(configuration: configuration, http: http, now: { fixedNow })
        let old = OAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: fixedNow)

        let fresh = try await client.refresh(old)
        #expect(fresh.accessToken == "access-2")
        #expect(fresh.refreshToken == "refresh-1")
        #expect(await http.formBody(at: 0)["grant_type"] == "refresh_token")

        await #expect(throws: OAuthError.tokenRequestFailed(status: 400, error: "invalid_grant")) {
            _ = try await client.refresh(old)
        }
    }

    @Test("Token descriptions are redacted")
    func redaction() {
        let tokens = OAuthTokens(accessToken: "secret-access", refreshToken: "secret-refresh", expiresAt: nil)
        for text in [String(describing: tokens), String(reflecting: tokens), "\(tokens)"] {
            #expect(!text.contains("secret"))
        }
    }
}

@Suite("Token provider and storage")
struct TokenProviderTests {
    private func makeProvider(
        tokens: OAuthTokens?,
        replies: [FakeHTTP.Reply]
    ) throws -> (TokenProvider, InMemoryTokenStore, FakeHTTP) {
        let store = InMemoryTokenStore()
        if let tokens { try store.save(tokens, forSource: "S1") }
        let http = FakeHTTP(replies)
        let client = OAuthClient(configuration: configuration, http: http, now: { fixedNow })
        return (TokenProvider(client: client, store: store, sourceId: "S1"), store, http)
    }

    @Test("A token with more than five minutes left is used as is")
    func validToken() async throws {
        let tokens = OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: fixedNow + 10 * 60)
        let (provider, _, http) = try makeProvider(tokens: tokens, replies: [])
        #expect(try await provider.validAccessToken() == "a1")
        #expect(await http.requestCount == 0)
    }

    @Test("A token within five minutes of expiry is refreshed first and the new one is stored")
    func refreshBeforeExpiry() async throws {
        let tokens = OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: fixedNow + 4 * 60)
        let (provider, store, http) = try makeProvider(
            tokens: tokens,
            replies: [.init(status: 200, body: tokenJSON(access: "a2", refresh: "r2"))]
        )
        #expect(try await provider.validAccessToken() == "a2")
        #expect(await http.requestCount == 1)
        #expect(try store.tokens(forSource: "S1")?.refreshToken == "r2")
    }

    @Test("Concurrent callers share one refresh")
    func sharedRefresh() async throws {
        let store = ReadCountingTokenStore()
        try store.save(OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: fixedNow), forSource: "S1")
        let http = GatedTokenHTTP()
        let client = OAuthClient(configuration: configuration, http: http, now: { fixedNow })
        let provider = TokenProvider(client: client, store: store, sourceId: "S1")

        async let first = provider.validAccessToken()
        async let second = provider.validAccessToken()
        // Each caller reads the store and, in the same actor turn, joins or starts the refresh. Once both
        // have read, the second has joined the first's refresh or sent its own request.
        for _ in 0..<100_000 where store.readCount < 2 {
            await Task.yield()
        }
        #expect(store.readCount == 2)
        await http.open()

        #expect(try await [first, second] == ["a2", "a2"])
        #expect(await http.requestCount == 1)
    }

    @Test("A rejected refresh or missing tokens mean the source must be re-linked; network errors pass through")
    func failures() async throws {
        let expiring = OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: fixedNow)
        let (rejected, _, _) = try makeProvider(
            tokens: expiring,
            replies: [.init(status: 400, body: #"{"error":"invalid_grant"}"#)]
        )
        await #expect(throws: RemoteSourceError.needsRelink) { _ = try await rejected.validAccessToken() }

        let (empty, _, _) = try makeProvider(tokens: nil, replies: [])
        await #expect(throws: RemoteSourceError.needsRelink) { _ = try await empty.validAccessToken() }

        let (offline, _, _) = try makeProvider(tokens: expiring, replies: [])
        await #expect(throws: URLError.self) { _ = try await offline.validAccessToken() }
    }

    @Test("Signing out revokes with the bearer token and deletes the tokens, even if revocation fails")
    func signOut() async throws {
        let tokens = OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: nil)
        let (provider, store, http) = try makeProvider(tokens: tokens, replies: [.init(status: 500, body: "")])
        try await provider.signOut()

        let sent = await http.requests
        #expect(sent.first?.url?.path() == "/2/auth/token/revoke")
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer a1")
        #expect(try store.tokens(forSource: "S1") == nil)
    }

    @Test("An unreadable Keychain item means re-link, and signing out still deletes it")
    func undecodableItem() async throws {
        let store = FlakyTokenStore()
        store.undecodable = true
        let client = OAuthClient(configuration: configuration, http: FakeHTTP([]), now: { fixedNow })
        let provider = TokenProvider(client: client, store: store, sourceId: "S1")

        await #expect(throws: RemoteSourceError.needsRelink) { _ = try await provider.validAccessToken() }
        try await provider.signOut()
        #expect(store.deleteCount == 1)
    }

    @Test("Fresh tokens survive a failed Keychain save and are saved on the next use")
    func failedSaveAfterRefresh() async throws {
        let store = FlakyTokenStore()
        try store.save(OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: fixedNow), forSource: "S1")
        store.failingSaves = 1
        let http = FakeHTTP([.init(status: 200, body: tokenJSON(access: "a2", refresh: "r2"))])
        let client = OAuthClient(configuration: configuration, http: http, now: { fixedNow })
        let provider = TokenProvider(client: client, store: store, sourceId: "S1")

        #expect(try await provider.validAccessToken() == "a2")
        #expect(try store.tokens(forSource: "S1")?.refreshToken == "r1", "the save failed")

        #expect(try await provider.validAccessToken() == "a2")
        #expect(await http.requestCount == 1, "no second refresh: the unsaved tokens were used")
        #expect(try store.tokens(forSource: "S1")?.refreshToken == "r2", "saved on the next use")
    }

    @Test("Without a refresh token, an expiring source needs re-linking")
    func noRefreshToken() async throws {
        let tokens = OAuthTokens(accessToken: "a1", refreshToken: nil, expiresAt: fixedNow)
        let (provider, _, http) = try makeProvider(tokens: tokens, replies: [])
        await #expect(throws: RemoteSourceError.needsRelink) { _ = try await provider.validAccessToken() }
        #expect(await http.requestCount == 0)
    }

    @Test("Tokens from a sign-in never reach UserDefaults")
    func notInUserDefaults() async throws {
        let (provider, store, _) = try makeProvider(tokens: nil, replies: [])
        let tokens = OAuthTokens(accessToken: "unique-access-7f3a", refreshToken: "unique-refresh-7f3a", expiresAt: nil)
        try await provider.signedIn(with: tokens)
        #expect(try store.tokens(forSource: "S1") == tokens)

        let defaults = UserDefaults.standard.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }
        #expect(!defaults.contains { $0.contains("7f3a") })
    }

    @Test("Keychain items are per source, this-device-only, and readable after first unlock")
    func keychainAttributes() {
        let store = KeychainTokenStore(kind: .dropbox)
        let query = store.addQuery(account: "S1", data: Data("x".utf8))
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "ereader.dropbox")
        #expect(query[kSecAttrAccount as String] as? String == "S1")
        #expect(
            query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }
}

/// A token store that can fail on purpose: unreadable items and failing saves.
private final class FlakyTokenStore: TokenStore, @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var storage: [String: OAuthTokens] = [:]
    private var _undecodable = false
    private var _failingSaves = 0
    private var _deleteCount = 0

    var undecodable: Bool {
        get { lock.withLock { _undecodable } }
        set { lock.withLock { _undecodable = newValue } }
    }
    var failingSaves: Int {
        get { lock.withLock { _failingSaves } }
        set { lock.withLock { _failingSaves = newValue } }
    }
    var deleteCount: Int { lock.withLock { _deleteCount } }

    func tokens(forSource sourceId: String) throws -> OAuthTokens? {
        try lock.withLock {
            if _undecodable { throw KeychainError.undecodableItem }
            return storage[sourceId]
        }
    }

    func save(_ tokens: OAuthTokens, forSource sourceId: String) throws {
        try lock.withLock {
            if _failingSaves > 0 {
                _failingSaves -= 1
                throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
            }
            storage[sourceId] = tokens
        }
    }

    func deleteTokens(forSource sourceId: String) throws {
        lock.withLock {
            _deleteCount += 1
            storage[sourceId] = nil
        }
    }

    func storedSourceIds() throws -> [String] {
        lock.withLock { Array(storage.keys) }
    }
}
