import Core
import Foundation
import Persistence
import Testing

@Suite("Library source repository")
struct LibrarySourceRepositoryTests {
    let repositories: DatabaseRepositories

    init() throws {
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
    }

    @Test("Sources round-trip, are listed in kind order, and one service links once")
    func addAndList() async throws {
        let dropbox = LibrarySource(kind: .dropbox, accountLabel: "a@example.com", rootId: "", rootDisplayPath: "/")
        let iCloud = LibrarySource(kind: .iCloud, rootBookmark: Data([1, 2, 3]), rootDisplayPath: "/Books")
        try await repositories.sources.addSource(dropbox)
        try await repositories.sources.addSource(iCloud)

        #expect(try await repositories.sources.source(id: dropbox.id) == dropbox)
        #expect(try await repositories.sources.source(kind: .iCloud) == iCloud)
        #expect(try await repositories.sources.source(kind: .oneDrive) == nil)

        var iterator = repositories.sources.observeSources().makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.kind) == [.iCloud, .dropbox])

        await #expect(throws: RepositoryError.sourceAlreadyLinked) {
            try await repositories.sources.addSource(LibrarySource(kind: .dropbox))
        }
        await #expect(throws: RepositoryError.localIsNotASource) {
            try await repositories.sources.addSource(LibrarySource(kind: .local))
        }
    }

    @Test("Sync results update status and cursor; changing the folder clears the cursor")
    func syncState() async throws {
        let source = LibrarySource(kind: .oneDrive, rootId: "root")
        try await repositories.sources.addSource(source)
        let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)

        try await repositories.sources.recordSyncFailure(id: source.id, status: .needsRelink, message: "Sign in again")
        var stored = try #require(try await repositories.sources.source(id: source.id))
        #expect(stored.status == .needsRelink)
        #expect(stored.lastSyncError == "Sign in again")

        try await repositories.sources.recordSyncSuccess(id: source.id, cursor: "delta-1", at: syncedAt)
        stored = try #require(try await repositories.sources.source(id: source.id))
        #expect(stored.status == .ok)
        #expect(stored.lastSyncError == nil)
        #expect(stored.syncCursor == "delta-1")
        #expect(stored.lastSyncedAt == syncedAt)

        try await repositories.sources.recordSyncFailure(id: source.id, status: .error, message: "Offline")
        stored = try #require(try await repositories.sources.source(id: source.id))
        #expect(stored.syncCursor == "delta-1", "a failed sync keeps the last good cursor")

        try await repositories.sources.changeRoot(
            id: source.id,
            rootId: "item-42",
            rootBookmark: nil,
            rootDisplayPath: "/Books"
        )
        stored = try #require(try await repositories.sources.source(id: source.id))
        #expect(stored.rootId == "item-42")
        #expect(stored.rootDisplayPath == "/Books")
        #expect(stored.syncCursor == nil)
    }
}
