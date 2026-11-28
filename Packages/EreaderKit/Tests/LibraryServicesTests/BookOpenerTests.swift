import BookStorage
import Core
import Foundation
import LibraryServices
import Persistence
import RemoteSources
import RemoteSourcesTesting
import Testing

@Suite("Tapping a book")
struct BookOpenerTests {
    let root: URL
    let files: BookFileStore
    let repositories: DatabaseRepositories
    let downloads: DownloadManager
    let remote = FakeRemoteSource(kind: .dropbox)
    let source = LibrarySource(kind: .dropbox, rootId: "", rootDisplayPath: "/")
    let opened = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        files = BookFileStore(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
        downloads = DownloadManager(books: repositories.books, files: files, retry: RetryPolicy(maxAttempts: 1))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// An opener that reads the fake source, or no source at all when `readable` is false.
    private func opener(readable: Bool = true) -> BookOpener {
        let remote = remote
        let opened = opened
        return BookOpener(
            books: repositories.books,
            sources: repositories.sources,
            files: files,
            downloads: downloads,
            remote: { _ in readable ? remote : nil },
            now: { opened }
        )
    }

    /// A synced, not-downloaded book whose file is in the fake source.
    private func syncedBook() async throws -> Book {
        try await repositories.sources.addSource(source)
        let file = await remote.putFile("/Books/Earthsea.epub", data: Data("the whole book".utf8))
        var book = Book(sourceKind: .dropbox, title: "A Wizard of Earthsea", authorRaw: "Ursula K. Le Guin")
        book.sourceId = source.id
        book.remoteId = file.remoteId
        book.remotePath = file.displayPath
        book.fileSize = file.size
        book.remoteVersion = file.version
        try await repositories.books.save(book)
        return book
    }

    /// A local import with its file on the device.
    private func localBook(withFile: Bool = true) async throws -> Book {
        var book = Book(sourceKind: .local, title: "The Tombs of Atuan", authorRaw: "Ursula K. Le Guin")
        let path = "Books/local/\(book.id).epub"
        book.localFilePath = path
        book.downloadState = .downloaded
        if withFile {
            let url = files.url(forBookPath: path)
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("epub".utf8).write(to: url)
        }
        try await repositories.books.save(book)
        return book
    }

    private func waitForHeldDownloads(_ count: Int) async throws {
        for _ in 0..<2_000 {
            if await remote.heldDownloads == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("the download never started")
    }

    @Test("A downloaded book opens at once and is marked opened")
    func opensDownloaded() async throws {
        defer { cleanUp() }
        let book = try await localBook()
        guard case .open(let open) = await opener().tap(book.id) else {
            Issue.record("didn't open")
            return
        }
        #expect(open.id == book.id)
        #expect(open.lastOpenedAt == opened)
        #expect(await remote.downloadCount == 0)
    }

    @Test("A book that isn't downloaded is downloaded, then opened")
    func downloadsThenOpens() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        guard case .open(let open) = await opener().tap(book.id) else {
            Issue.record("didn't open")
            return
        }
        #expect(open.downloadState == .downloaded)
        #expect(open.lastOpenedAt == opened)
        #expect(await remote.downloadCount == 1)
    }

    @Test("Tapping a book while it downloads cancels the download, and the first tap says so", .timeLimit(.minutes(1)))
    func tapAgainCancels() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        await remote.holdDownloads()
        let opener = opener()
        let first = Task { await opener.tap(book.id) }
        try await waitForHeldDownloads(1)

        #expect(await opener.tap(book.id) == .cancelled)
        #expect(await first.value == .cancelled)
        let stored = try #require(try await repositories.books.book(id: book.id))
        #expect(stored.downloadState == .notDownloaded)
        #expect(stored.lastOpenedAt == nil)
    }

    @Test("Download failures become reasons the library can show")
    func failures() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        #expect(await opener(readable: false).tap(book.id) == .failed(.notDownloadable))

        await remote.removeFile("/Books/Earthsea.epub")
        #expect(await opener().tap(book.id) == .failed(.missingFromSource))

        await remote.expireAuth()
        #expect(await opener().tap(book.id) == .failed(.needsRelink))
        #expect(try await repositories.books.book(id: book.id)?.lastOpenedAt == nil)
    }

    @Test("A local book whose file is gone can't be opened")
    func missingLocalFile() async throws {
        defer { cleanUp() }
        let book = try await localBook(withFile: false)
        #expect(await opener().tap(book.id) == .failed(.fileMissing))
    }

    @Test("An out-of-date copy is downloaded again, or opened as it is when that fails")
    func staleCopy() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        _ = try await downloads.download(book.id, from: remote)
        // The file changes in the source; the next sync records the new version.
        let changed = await remote.putFile("/Books/Earthsea.epub", data: Data("a newer edition".utf8))
        try await repositories.books.updateBook(id: book.id) { book in
            book.remoteVersion = changed.version
            book.fileSize = changed.size
        }

        await remote.expireAuth()
        guard case .open(let offline) = await opener().tap(book.id) else {
            Issue.record("the old copy didn't open")
            return
        }
        #expect(offline.isDownloadStale)

        _ = try await remote.link()
        guard case .open(let updated) = await opener().tap(book.id) else {
            Issue.record("didn't open")
            return
        }
        #expect(!updated.isDownloadStale)
        #expect(await remote.downloadCount == 2)
    }

    @Test(
        "Errors map to what the library explains",
        arguments: [
            (URLError(.notConnectedToInternet), BookOpenError.offline),
            (URLError(.timedOut), .offline),
            (URLError(.badServerResponse), .downloadFailed),
            (RemoteSourceError.needsRelink, .needsRelink),
            (RemoteSourceError.notFound, .missingFromSource),
            (RemoteSourceError.rateLimited(retryAfter: 3), .downloadFailed),
            (DownloadError.sizeMismatch(expected: 3, actual: 4), .changedInSource),
            (DownloadError.notDownloadable, .notDownloadable),
        ] as [(any Error & Sendable, BookOpenError)]
    )
    func mapping(error: any Error & Sendable, expected: BookOpenError) {
        #expect(BookOpenError.from(error) == expected)
    }
}
