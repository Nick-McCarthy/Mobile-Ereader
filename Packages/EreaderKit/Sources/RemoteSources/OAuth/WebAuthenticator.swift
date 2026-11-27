import Foundation

/// Shows the provider's sign-in page and returns the redirect URL. Tests substitute a fake.
public protocol WebAuthenticator: Sendable {
    /// Throws `RemoteSourceError.cancelled` if the user closes the sheet.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

#if os(iOS)
    import AuthenticationServices
    import UIKit

    /// Sign-in through `ASWebAuthenticationSession`: the system browser sheet, never an embedded web view,
    /// so the app never sees the user's password. The session is ephemeral (no shared Safari cookies).
    @MainActor
    public final class SystemWebAuthenticator: NSObject, WebAuthenticator {
        private var session: ASWebAuthenticationSession?

        override public init() {
            super.init()
        }

        public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
            defer { session = nil }
            return try await withCheckedThrowingContinuation { continuation in
                let handler: @Sendable (URL?, (any Error)?) -> Void = { callback, error in
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: RemoteSourceError.cancelled)
                    } else {
                        continuation.resume(throwing: error ?? RemoteSourceError.cancelled)
                    }
                }
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme,
                    completionHandler: handler
                )
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() {
                    continuation.resume(throwing: RemoteSourceError.cancelled)
                }
            }
        }
    }

    extension SystemWebAuthenticator: ASWebAuthenticationPresentationContextProviding {
        public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                let windows = scenes.flatMap(\.windows)
                if let window = windows.first(where: \.isKeyWindow) ?? windows.first { return window }
                guard let scene = scenes.first else { preconditionFailure("Sign-in needs a window scene") }
                return UIWindow(windowScene: scene)
            }
        }
    }
#endif
