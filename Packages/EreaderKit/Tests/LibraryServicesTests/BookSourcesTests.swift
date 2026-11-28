import BookStorage
import Core
import Foundation
import LibraryServices
import Persistence
import RemoteSources
import Testing

@Suite("Book sources")
struct BookSourcesTests {
    let root: URL
    let folder: URL
    let repositories: DatabaseRepositories
    let bookSources: BookSources

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folder = root.appendingPathComponent("My Books", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
        bookSources = BookSources(sources: repositories.sources)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Linking a folder saves an iCloud source with its bookmark; a second folder is refused")
    func linkFolder() async throws {
        defer { cleanUp() }
        let source = try await bookSources.linkFolder(at: folder)

        let saved = try #require(try await repositories.sources.source(kind: .iCloud))
        #expect(saved == source)
        #expect(saved.accountLabel == "My Books")
        #expect(saved.rootDisplayPath == "/My Books")
        #expect(saved.rootId == "")
        #expect(saved.rootBookmark != nil)
        #expect(try await bookSources.linkedSources().map(\.id) == [source.id])

        await #expect(throws: RepositoryError.sourceAlreadyLinked) {
            try await bookSources.linkFolder(at: folder)
        }
    }

    @Test("A file isn't a folder")
    func linkFile() async throws {
        defer { cleanUp() }
        let file = folder.appendingPathComponent("book.epub")
        try Data("x".utf8).write(to: file)
        await #expect(throws: RemoteSourceError.notFound) { try await bookSources.linkFolder(at: file) }
        #expect(try await repositories.sources.source(kind: .iCloud) == nil)
    }

    @Test("Only iCloud has an adapter in this version")
    func adapters() {
        #expect(BookSources.isAvailable(.iCloud))
        #expect(!BookSources.isAvailable(.dropbox))
        #expect(!BookSources.isAvailable(.oneDrive))
        let dropbox = LibrarySource(kind: .dropbox)
        let iCloud = LibrarySource(kind: .iCloud, rootBookmark: Data([1]))
        #expect(bookSources.remote(for: dropbox) == nil)
        #expect(bookSources.remote(for: iCloud)?.kind == .iCloud)
        #expect(bookSources.syncTargets(for: [dropbox, iCloud]).map(\.source.id) == [iCloud.id])
    }

    @Test("Changing the folder saves a new bookmark and path and clears the cursor")
    func changeFolder() async throws {
        defer { cleanUp() }
        let source = try await bookSources.linkFolder(at: folder)
        try await repositories.sources.recordSyncSuccess(id: source.id, cursor: "files:1", at: Date())
        let other = root.appendingPathComponent("Other Books", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        try await bookSources.changeFolder(of: source.id, to: other)

        let saved = try #require(try await repositories.sources.source(id: source.id))
        #expect(saved.rootDisplayPath == "/Other Books")
        #expect(saved.rootBookmark != source.rootBookmark)
        #expect(saved.syncCursor == nil)
    }

    @Test("A linked folder syncs end to end through the real iCloud adapter")
    func syncLinkedFolder() async throws {
        defer { cleanUp() }
        let nested = folder.appendingPathComponent("Fantasy", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let epub = try await EPUBBytes.make(title: "A Wizard of Earthsea")
        try epub.write(to: nested.appendingPathComponent("Earthsea.epub"))
        try await bookSources.linkFolder(at: folder)
        let files = BookFileStore(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
        let engine = SyncEngine(
            books: repositories.books,
            series: repositories.series,
            sources: repositories.sources,
            files: files
        )

        let targets = bookSources.syncTargets(for: try await bookSources.linkedSources())
        let outcomes = try await engine.sync(targets)
        await bookSources.saveRefreshedBookmarks(targets)

        let source = try #require(targets.first?.source)
        #expect(outcomes == [source.id: .synced])
        let books = try await repositories.books.books(inSource: source.id)
        #expect(books.map(\.title) == ["A Wizard of Earthsea"])
        #expect(books.first?.remoteId == "Fantasy/Earthsea.epub")
    }
}
