import BookStorage
import Core
import Foundation
import LibraryServices
import Persistence
import RemoteSources
import RemoteSourcesTesting
import Testing

@Suite("Unlinking and detached books")
struct SourceUnlinkTests {
    let root: URL
    let files: BookFileStore
    let repositories: DatabaseRepositories
    let downloads: DownloadManager
    let unlinker: SourceUnlinker
    let check: DetachedBookCheck

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        files = BookFileStore(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
        downloads = DownloadManager(books: repositories.books, files: files)
        unlinker = SourceUnlinker(
            books: repositories.books,
            sources: repositories.sources,
            files: files,
            downloads: downloads
        )
        check = DetachedBookCheck(books: repositories.books, files: files)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func isExcludedFromBackup(_ book: Book) throws -> Bool? {
        let url = files.url(forBookPath: try #require(book.localFilePath))
        return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    private func engine() -> SyncEngine {
        SyncEngine(
            books: repositories.books,
            series: repositories.series,
            sources: repositories.sources,
            files: files,
            retry: RetryPolicy(sleep: { _ in }, jitter: { 1 })
        )
    }

    /// Links a fresh source of `kind` reading `remote`, and syncs it.
    private func linkAndSync(_ remote: FakeRemoteSource) async throws -> LibrarySource {
        let source = LibrarySource(kind: remote.kind, rootId: "", rootDisplayPath: "/")
        try await repositories.sources.addSource(source)
        _ = try await remote.link()
        let outcomes = try await engine().sync([SyncTarget(source: source, remote: remote)])
        #expect(outcomes[source.id] == .synced)
        return source
    }

    private func book(at remoteId: String, in source: LibrarySource) async throws -> Book {
        try #require(try await repositories.books.books(inSource: source.id).first { $0.remoteId == remoteId })
    }

    private func titles(matching text: String) async throws -> [String] {
        try await repositories.books.fetchLibrary(LibraryQuery(searchText: text)).map(\.title)
    }

    // MARK: Unlinking

    @Test("Unlinking removes books that aren't downloaded, with all their data, and detaches downloaded ones")
    func unlinkMixed() async throws {
        defer { cleanUp() }
        let remote = FakeRemoteSource(kind: .dropbox)
        await remote.putFile("/Cloud.epub", data: try await EPUBBytes.make(title: "Cloud Only", series: ("Sky", 1)))
        await remote.putFile("/Local.epub", data: try await EPUBBytes.make(title: "On Device"))
        let source = try await linkAndSync(remote)
        let cloud = try await book(at: "/Cloud.epub", in: source)
        let onDevice = try await downloads.download(try await book(at: "/Local.epub", in: source).id, from: remote)

        // Reading data and memberships on the book that will be removed.
        let favourites = try await repositories.collections.createCollection(named: "Favourites")
        try await repositories.collections.addBook(cloud.id, toCollection: favourites.id)
        try await repositories.bookmarks.addBookmark(Bookmark(bookId: cloud.id, locatorJSON: "{}", progression: 0.2))
        try await repositories.readingPositions.savePosition(
            ReadingPosition(bookId: cloud.id, locatorJSON: "{}"),
            progression: 0.2
        )
        let cover = files.url(forCoverPath: "\(cloud.id).jpg")
        try FileManager.default.createDirectory(at: files.coversDirectory, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: cover)
        try await repositories.books.updateBook(id: cloud.id) { $0.coverPath = "\(cloud.id).jpg" }

        #expect(try await unlinker.preview(sourceId: source.id) == UnlinkPreview(notDownloaded: 1, downloaded: 1))
        let changes = try await unlinker.unlink(sourceId: source.id, remote: remote)

        #expect(changes.removed.map(\.id) == [cloud.id])
        #expect(changes.detached.map(\.id) == [onDevice.id])
        // Removed, and everything that hung off it.
        #expect(try await repositories.books.book(id: cloud.id) == nil)
        #expect(try await repositories.readingPositions.position(forBook: cloud.id) == nil)
        var bookmarks = repositories.bookmarks.observeBookmarks(forBook: cloud.id).makeAsyncIterator()
        #expect(try await bookmarks.next()?.isEmpty == true)
        var inFavourites = repositories.collections.observeBooks(inCollection: favourites.id).makeAsyncIterator()
        #expect(try await inFavourites.next()?.isEmpty == true)
        #expect(try await titles(matching: "cloud").isEmpty)
        #expect(!exists(cover))
        // Collections and series stay, even when empty.
        var collections = repositories.collections.observeCollections().makeAsyncIterator()
        #expect(try await collections.next()?.map(\.name) == ["Favourites"])
        var series = repositories.series.observeSeries().makeAsyncIterator()
        #expect(try await series.next()?.map(\.name) == ["Sky"])

        // Detached: still readable, now backed up, and the source and its tokens are gone.
        let detached = try #require(try await repositories.books.book(id: onDevice.id))
        #expect(detached.isDetached)
        #expect(detached.sourceKind == .dropbox)
        #expect(detached.remoteId == "/Local.epub")
        #expect(exists(files.url(forBookPath: try #require(detached.localFilePath))))
        #expect(try isExcludedFromBackup(detached) == false)
        #expect(try await titles(matching: "device") == ["On Device"])
        #expect(try await repositories.sources.source(id: source.id) == nil)
        #expect(await !remote.isLinked)
    }

    @Test("Unlinking stops a running download first", .timeLimit(.minutes(1)))
    func unlinkCancelsDownload() async throws {
        defer { cleanUp() }
        let remote = FakeRemoteSource(kind: .dropbox)
        await remote.putFile("/Book.epub", data: try await EPUBBytes.make(title: "Book"))
        let source = try await linkAndSync(remote)
        let book = try await book(at: "/Book.epub", in: source)
        await remote.holdDownloads()
        let downloading = Task { try await downloads.download(book.id, from: remote) }
        for _ in 0..<2_000 {
            if await remote.heldDownloads > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        try await unlinker.unlink(sourceId: source.id, remote: remote)

        await #expect(throws: CancellationError.self) { try await downloading.value }
        #expect(try await repositories.books.book(id: book.id) == nil)
        #expect(!exists(files.url(forBookPath: "Books/remote/\(book.id).epub")))
    }

    // MARK: Integrity

    @Test("A detached book whose file is gone is removed; one with its file is kept")
    func missingDetachedFile() async throws {
        defer { cleanUp() }
        let remote = FakeRemoteSource(kind: .oneDrive)
        await remote.putFile("/Kept.epub", data: try await EPUBBytes.make(title: "Kept"))
        await remote.putFile("/Lost.epub", data: try await EPUBBytes.make(title: "Lost"))
        let source = try await linkAndSync(remote)
        let kept = try await downloads.download(try await book(at: "/Kept.epub", in: source).id, from: remote)
        let lost = try await downloads.download(try await book(at: "/Lost.epub", in: source).id, from: remote)
        try await unlinker.unlink(sourceId: source.id, remote: remote)
        try FileManager.default.removeItem(at: files.url(forBookPath: try #require(lost.localFilePath)))

        #expect(try await check.run() == 1)
        #expect(try await repositories.books.book(id: lost.id) == nil)
        #expect(try await repositories.books.book(id: kept.id) != nil)

        // The same check, for one book being opened.
        try FileManager.default.removeItem(at: files.url(forBookPath: try #require(kept.localFilePath)))
        #expect(try await check.removeIfFileMissing(kept.id))
        #expect(try await repositories.books.book(id: kept.id) == nil)
    }

    @Test("The integrity check leaves linked and local books alone")
    func integrityIgnoresAttachedBooks() async throws {
        defer { cleanUp() }
        let remote = FakeRemoteSource(kind: .dropbox)
        await remote.putFile("/Cloud.epub", data: try await EPUBBytes.make(title: "Cloud"))
        let source = try await linkAndSync(remote)
        let cloud = try await book(at: "/Cloud.epub", in: source)
        let local = Book(sourceKind: .local, title: "Local", authorRaw: nil)
        try await repositories.books.save(local)

        #expect(try await check.run() == 0)
        #expect(try await check.removeIfFileMissing(cloud.id) == false)
        #expect(try await check.removeIfFileMissing(local.id) == false)
        #expect(try await repositories.books.book(id: cloud.id) != nil)
    }

    // MARK: Re-linking

    @Test("Re-linking the service re-attaches detached books, keeping their data, without duplicates")
    func relinkReattaches() async throws {
        defer { cleanUp() }
        let remote = FakeRemoteSource(kind: .dropbox)
        await remote.putFile("/Read.epub", data: try await EPUBBytes.make(title: "Being Read"))
        await remote.putFile("/Unread.epub", data: try await EPUBBytes.make(title: "Unread"))
        let first = try await linkAndSync(remote)
        let read = try await downloads.download(try await book(at: "/Read.epub", in: first).id, from: remote)
        try await repositories.bookmarks.addBookmark(Bookmark(bookId: read.id, locatorJSON: "{}", progression: 0.6))
        try await unlinker.unlink(sourceId: first.id, remote: remote)

        let second = try await linkAndSync(remote)

        let books = try await repositories.books.books(inSource: second.id)
        #expect(books.count == 2)
        #expect(try await repositories.books.detachedBooks(kind: nil).isEmpty)
        let reattached = try await book(at: "/Read.epub", in: second)
        #expect(reattached.id == read.id)
        #expect(reattached.downloadState == .downloaded)
        #expect(!reattached.isDownloadStale)
        #expect(try isExcludedFromBackup(reattached) == true)
        var bookmarks = repositories.bookmarks.observeBookmarks(forBook: read.id).makeAsyncIterator()
        #expect(try await bookmarks.next()?.count == 1)
        #expect(try await repositories.books.fetchLibrary(LibraryQuery()).count == 2)
    }

    @Test("A re-linked file that changed meanwhile re-attaches and is marked stale; on iCloud it doesn't re-attach")
    func relinkChangedFile() async throws {
        defer { cleanUp() }
        for kind in [SourceKind.dropbox, .iCloud] {
            let remote = FakeRemoteSource(kind: kind, supportsRangedReads: kind != .iCloud)
            await remote.putFile("/Book.epub", data: try await EPUBBytes.make(title: "First Edition"))
            let first = try await linkAndSync(remote)
            let downloaded = try await downloads.download(try await book(at: "/Book.epub", in: first).id, from: remote)
            try await unlinker.unlink(sourceId: first.id, remote: remote)
            await remote.putFile("/Book.epub", data: try await EPUBBytes.make(title: "Second Edition"))

            let second = try await linkAndSync(remote)
            let listed = try await book(at: "/Book.epub", in: second)
            if kind == .iCloud {
                // On iCloud a remote id is a path, so a changed file at that path may be another book.
                #expect(listed.id != downloaded.id)
                #expect(try await repositories.books.book(id: downloaded.id)?.isDetached == true)
            } else {
                #expect(listed.id == downloaded.id)
                #expect(listed.title == "Second Edition")
                #expect(listed.isDownloadStale)
            }
        }
    }
}
