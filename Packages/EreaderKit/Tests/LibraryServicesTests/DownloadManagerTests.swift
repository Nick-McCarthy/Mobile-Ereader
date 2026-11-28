import BookStorage
import Core
import Foundation
import LibraryServices
import Persistence
import RemoteSources
import RemoteSourcesTesting
import Testing

@Suite("Download manager")
struct DownloadManagerTests {
    let root: URL
    let files: BookFileStore
    let repositories: DatabaseRepositories
    let manager: DownloadManager
    let remote = FakeRemoteSource(kind: .dropbox)
    let source = LibrarySource(kind: .dropbox, rootId: "", rootDisplayPath: "/")
    let bytes = Data("the whole book".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        files = BookFileStore(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
        manager = DownloadManager(books: repositories.books, files: files)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// A synced, not-downloaded book whose file is in the fake source.
    private func syncedBook(_ path: String = "/Books/Earthsea.epub") async throws -> Book {
        try await repositories.sources.addSource(source)
        let file = await remote.putFile(path, data: bytes)
        var book = Book(sourceKind: .dropbox, title: "A Wizard of Earthsea", authorRaw: "Ursula K. Le Guin")
        book.sourceId = source.id
        book.remoteId = file.remoteId
        book.remotePath = file.displayPath
        book.fileSize = file.size
        book.remoteVersion = file.version
        try await repositories.books.save(book)
        return book
    }

    private func stored(_ id: Book.ID) async throws -> Book {
        try #require(try await repositories.books.book(id: id))
    }

    /// Waits (up to about two seconds) until the fake source holds `count` downloads.
    private func waitForHeldDownloads(_ count: Int) async throws {
        for _ in 0..<2_000 {
            if await remote.heldDownloads == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("the download never started")
    }

    @Test("A download lands in Books/remote, excluded from backup, with the version it was fetched at")
    func downloads() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()

        let downloaded = try await manager.download(book.id, from: remote)

        #expect(downloaded.downloadState == .downloaded)
        #expect(downloaded.localFilePath == "Books/remote/\(book.id).epub")
        #expect(downloaded.localFileVersion == book.remoteVersion)
        #expect(!downloaded.isDownloadStale)
        #expect(try await stored(book.id) == downloaded)
        let url = files.url(forBookPath: try #require(downloaded.localFilePath))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(!exists(try files.partialDownloadURL(bookId: book.id)))
        #expect(await !manager.isDownloading(book.id))
    }

    @Test("An up-to-date download isn't fetched again; a stale one is replaced")
    func staleRedownload() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        try await manager.download(book.id, from: remote)
        try await manager.download(book.id, from: remote)
        #expect(await remote.downloadCount == 1)

        // A sync saw a new version of the file.
        let newBytes = Data("the revised book".utf8)
        let file = await remote.putFile(book.remotePath ?? "", data: newBytes)
        try await repositories.books.updateBook(id: book.id) { stored in
            stored.remoteVersion = file.version
            stored.fileSize = file.size
        }
        #expect(try await stored(book.id).isDownloadStale)

        let updated = try await manager.download(book.id, from: remote)
        #expect(await remote.downloadCount == 2)
        #expect(updated.localFileVersion == file.version)
        #expect(!updated.isDownloadStale)
        #expect(try Data(contentsOf: files.url(forBookPath: try #require(updated.localFilePath))) == newBytes)
    }

    @Test("Cancelling stops the download, deletes the partial file, and restores the state", .timeLimit(.minutes(1)))
    func cancel() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        await remote.holdDownloads()

        let task = Task { try await manager.download(book.id, from: remote) }
        try await waitForHeldDownloads(1)
        #expect(await manager.isDownloading(book.id))
        #expect(try await stored(book.id).downloadState == .downloading)
        await manager.cancel(book.id)

        await #expect(throws: CancellationError.self) { try await task.value }
        let after = try await stored(book.id)
        #expect(after.downloadState == .notDownloaded)
        #expect(after.localFilePath == nil)
        #expect(!exists(try files.partialDownloadURL(bookId: book.id)))
        #expect(!exists(files.url(forBookPath: "Books/remote/\(book.id).epub")))
    }

    @Test("Two requests for the same book share one download", .timeLimit(.minutes(1)))
    func joinsRunningDownload() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        await remote.holdDownloads()

        let first = Task { try await manager.download(book.id, from: remote) }
        try await waitForHeldDownloads(1)
        let second = Task { try await manager.download(book.id, from: remote) }
        await Task.yield()
        await remote.releaseDownloads()

        let (a, b) = (try await first.value, try await second.value)
        #expect(a.localFilePath == b.localFilePath)
        #expect(await remote.downloadCount == 1)
    }

    @Test("Progress is reported while downloading and cleared when it ends", .timeLimit(.minutes(1)))
    func progress() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        await remote.holdDownloads()
        var updates = manager.observeProgress().makeAsyncIterator()
        #expect(await updates.next() == [:])

        let task = Task { try await manager.download(book.id, from: remote) }
        var sawHalfway = false
        while let snapshot = await updates.next() {
            if snapshot[book.id] == 0.5 {
                sawHalfway = true
                await remote.releaseDownloads()
            }
            if sawHalfway, snapshot.isEmpty { break }
        }
        #expect(sawHalfway)
        _ = try await task.value
    }

    @Test("A file whose size doesn't match the last sync is rejected and nothing is kept")
    func sizeMismatch() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        try await repositories.books.updateBook(id: book.id) { $0.fileSize = 999 }

        await #expect(throws: DownloadError.sizeMismatch(expected: 999, actual: Int64(bytes.count))) {
            try await manager.download(book.id, from: remote)
        }
        let after = try await stored(book.id)
        #expect(after.downloadState == .failed)
        #expect(after.localFilePath == nil)
        #expect(!exists(files.url(forBookPath: "Books/remote/\(book.id).epub")))
    }

    @Test("Lost access fails the download with needsRelink")
    func needsRelink() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        await remote.expireAuth()

        await #expect(throws: RemoteSourceError.needsRelink) {
            try await manager.download(book.id, from: remote)
        }
        #expect(try await stored(book.id).downloadState == .failed)
    }

    @Test("Remove Download deletes the file and keeps the book and its progress")
    func removeDownload() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        let downloaded = try await manager.download(book.id, from: remote)
        try await repositories.books.updateBook(id: book.id) { $0.progression = 0.3 }
        let url = files.url(forBookPath: try #require(downloaded.localFilePath))

        #expect(try await manager.removeDownload(book.id) == .removed)
        let after = try await stored(book.id)
        #expect(after.downloadState == .notDownloaded)
        #expect(after.localFilePath == nil)
        #expect(after.localFileVersion == nil)
        #expect(after.progression == 0.3)
        #expect(!exists(url))
        #expect(try await manager.removeDownload(book.id) == .nothingToRemove)
    }

    @Test("Remove Download on a detached book removes the book too, and it can't be downloaded")
    func removeDetached() async throws {
        defer { cleanUp() }
        let book = try await syncedBook()
        let downloaded = try await manager.download(book.id, from: remote)
        let url = files.url(forBookPath: try #require(downloaded.localFilePath))
        try await repositories.books.updateBook(id: book.id) { $0.sourceId = nil }

        await #expect(throws: DownloadError.notDownloadable) {
            try await repositories.books.updateBook(id: book.id) { $0.downloadState = .notDownloaded }
            try await manager.download(book.id, from: remote)
        }
        #expect(try await manager.removeDownload(book.id) == .removedFromLibrary)
        #expect(try await repositories.books.book(id: book.id) == nil)
        #expect(!exists(url))
    }

    @Test("Local imports and unknown ids are refused")
    func refused() async throws {
        defer { cleanUp() }
        let local = Book(sourceKind: .local, title: "Imported", authorRaw: nil)
        try await repositories.books.save(local)

        await #expect(throws: DownloadError.notDownloadable) { try await manager.download(local.id, from: remote) }
        await #expect(throws: DownloadError.notDownloadable) { try await manager.removeDownload(local.id) }
        await #expect(throws: DownloadError.bookNotFound) { try await manager.download("missing", from: remote) }
    }
}
