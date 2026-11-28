import Core
import Foundation
import Persistence
import Testing

@Suite("Book repository: sync")
struct BookSyncRepositoryTests {
    let repositories: DatabaseRepositories
    let source = LibrarySource(kind: .dropbox, rootId: "", rootDisplayPath: "/")

    init() throws {
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
    }

    private func remoteBook(_ remoteId: String, sourceId: String?) -> Book {
        var book = Book(sourceKind: .dropbox, title: remoteId, authorRaw: "Someone")
        book.sourceId = sourceId
        book.remoteId = remoteId
        book.remotePath = "/\(remoteId)"
        return book
    }

    @Test("books(inSource:) returns only that source's books, missing ones included")
    func booksInSource() async throws {
        try await repositories.sources.addSource(source)
        let other = LibrarySource(kind: .oneDrive)
        try await repositories.sources.addSource(other)
        var missing = remoteBook("a.epub", sourceId: source.id)
        missing.isMissingFromSource = true
        try await repositories.books.save(missing)
        try await repositories.books.save(remoteBook("b.epub", sourceId: other.id))
        try await repositories.books.save(Book(sourceKind: .local, title: "Local", authorRaw: nil))

        let found = try await repositories.books.books(inSource: source.id)
        #expect(found.map(\.remoteId) == ["a.epub"])
    }

    @Test("applyListing inserts, relists (clearing missing), and flags missing books in one go")
    func applyListing() async throws {
        try await repositories.sources.addSource(source)
        var known = remoteBook("known.epub", sourceId: source.id)
        known.isMissingFromSource = true
        known.title = "Kept Title"
        let gone = remoteBook("gone.epub", sourceId: source.id)
        try await repositories.books.save(known)
        try await repositories.books.save(gone)
        let new = remoteBook("new.epub", sourceId: source.id)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)

        let moved = RelistedBook(
            id: known.id,
            remotePath: "/Moved/known.epub",
            fileSize: 42,
            remoteModifiedAt: modified
        )
        try await repositories.books.applyListing(
            BookListingChanges(inserted: [new], relisted: [moved], missing: [gone.id])
        )

        let relisted = try #require(try await repositories.books.book(id: known.id))
        #expect(relisted.remotePath == "/Moved/known.epub")
        #expect(relisted.fileSize == 42)
        #expect(relisted.remoteModifiedAt == modified)
        #expect(!relisted.isMissingFromSource)
        #expect(relisted.title == "Kept Title")
        #expect(try await repositories.books.book(id: gone.id)?.isMissingFromSource == true)
        #expect(try await repositories.books.book(id: new.id)?.remoteId == "new.epub")
    }

    @Test("applyListing is all or nothing")
    func applyListingIsAtomic() async throws {
        try await repositories.sources.addSource(source)
        let existing = remoteBook("a.epub", sourceId: source.id)
        try await repositories.books.save(existing)
        // The second insert breaks the unique (sourceId, remoteId) key, so nothing may be saved.
        let duplicate = remoteBook("a.epub", sourceId: source.id)
        await #expect(throws: (any Error).self) {
            try await repositories.books.applyListing(
                BookListingChanges(
                    inserted: [remoteBook("b.epub", sourceId: source.id), duplicate],
                    missing: [existing.id]
                )
            )
        }
        #expect(try await repositories.books.books(inSource: source.id).count == 1)
        #expect(try await repositories.books.book(id: existing.id)?.isMissingFromSource == false)
    }

    @Test("updateBook changes a stored book and returns it; an unknown id returns nil")
    func updateBook() async throws {
        let book = Book(sourceKind: .local, title: "Old", authorRaw: nil)
        try await repositories.books.save(book)

        let updated = try await repositories.books.updateBook(id: book.id) { $0.publisher = "Parnassus" }
        #expect(updated?.publisher == "Parnassus")
        #expect(try await repositories.books.book(id: book.id)?.publisher == "Parnassus")
        #expect(try await repositories.books.updateBook(id: "nope") { $0.publisher = "x" } == nil)
    }

    @Test("A downloaded copy is stale once the source's version moves past it")
    func downloadStale() async throws {
        var book = remoteBook("a.epub", sourceId: nil)
        book.remoteVersion = "v1"
        #expect(!book.isDownloadStale)  // not downloaded
        book.downloadState = .downloaded
        book.localFileVersion = "v1"
        #expect(!book.isDownloadStale)
        book.remoteVersion = "v2"
        #expect(book.isDownloadStale)

        try await repositories.books.save(book)
        #expect(try await repositories.books.book(id: book.id)?.localFileVersion == "v1")

        var local = Book(sourceKind: .local, title: "Local", authorRaw: nil)
        local.downloadState = .downloaded
        #expect(!local.isDownloadStale)
    }
}
