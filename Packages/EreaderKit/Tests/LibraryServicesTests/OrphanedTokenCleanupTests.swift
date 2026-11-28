import Core
import LibraryServices
import Persistence
import RemoteSources
import RemoteSourcesTesting
import Testing

@Suite("Orphaned token cleanup")
struct OrphanedTokenCleanupTests {
    let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: nil)

    @Test("Tokens without a linked source are deleted; the linked source's tokens are kept")
    func removesOrphans() async throws {
        let repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
        let linked = LibrarySource(id: "linked", kind: .dropbox)
        try await repositories.sources.addSource(linked)
        let dropbox = InMemoryTokenStore()
        let oneDrive = InMemoryTokenStore()
        try dropbox.save(tokens, forSource: "linked")
        try dropbox.save(tokens, forSource: "old-install")
        try oneDrive.save(tokens, forSource: "old-onedrive")

        let cleanup = OrphanedTokenCleanup(
            sources: repositories.sources,
            stores: [.dropbox: dropbox, .oneDrive: oneDrive]
        )
        #expect(try await cleanup.run() == 2)
        #expect(try dropbox.storedSourceIds() == ["linked"])
        #expect(try oneDrive.storedSourceIds().isEmpty)

        #expect(try await cleanup.run() == 0, "a second run has nothing left to remove")
    }
}
