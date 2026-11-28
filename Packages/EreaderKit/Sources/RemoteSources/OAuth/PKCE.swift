import CryptoKit
import Foundation
import Security

/// Proof Key for Code Exchange (RFC 7636), `S256` method.
public struct PKCE: Equatable, Sendable {
    /// Sent only in the token request; never leaves the device before that.
    public let verifier: String
    /// base64url(SHA-256(verifier)), sent in the authorisation URL.
    public let challenge: String
    public let method = "S256"

    /// A fresh verifier from 32 random bytes (43 characters, as RFC 7636 recommends).
    public init() throws {
        try self.init(verifier: OAuthRandom.base64URL(byteCount: 32))
    }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = OAuthRandom.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

enum OAuthRandom {
    struct RandomUnavailable: Error {}

    /// `byteCount` bytes from the system's secure random generator, base64url-encoded without padding.
    static func base64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw RandomUnavailable()
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-")
        text = text.replacingOccurrences(of: "/", with: "_")
        return text.replacingOccurrences(of: "=", with: "")
    }
}
