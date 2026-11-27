import Core
import Persistence
import RemoteSources

/// Deletes Keychain tokens that no linked source owns.
///
/// Keychain items survive deleting the app, but the database doesn't, so after a reinstall (or a lost
/// database) the old tokens would stay on the device forever. Run once per launch, off the main actor.
/// See docs/SECURITY_AND_APP_STORE.md and finding F-A1 in docs/audit-stage-1-findings.md.
public struct OrphanedTokenCleanup: Sendable {
    let sources: any LibrarySourceRepository
    let stores: [SourceKind: any TokenStore]

    public init(sources: any LibrarySourceRepository, stores: [SourceKind: any TokenStore]) {
        self.sources = sources
        self.stores = stores
    }

    /// The app's real Keychain stores, one per service that signs in.
    public static func keychainStores() -> [SourceKind: any TokenStore] {
        [.dropbox: KeychainTokenStore(kind: .dropbox), .oneDrive: KeychainTokenStore(kind: .oneDrive)]
    }

    /// Removes every token item whose source id isn't the linked source of that kind. Returns how many.
    @discardableResult
    @concurrent
    public func run() async throws -> Int {
        var removed = 0
        for (kind, store) in stores {
            let linkedId = try await sources.source(kind: kind)?.id
            for sourceId in try store.storedSourceIds() where sourceId != linkedId {
                try store.deleteTokens(forSource: sourceId)
                removed += 1
            }
        }
        return removed
    }
}
