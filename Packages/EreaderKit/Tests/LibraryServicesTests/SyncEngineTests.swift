import BookStorage
import Core
import Foundation
import LibraryServices
import Persistence
import ReadiumZIPFoundation
import RemoteSources
import RemoteSourcesTesting
import Testing

@Suite("Sync engine")
struct SyncEngineTests {
    let root: URL
    let files: BookFileStore
    let repositories: DatabaseRepositories
    let sleeps = SleepLog()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = BookFileStore(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// An engine whose retries are recorded instead of slept, with no jitter.
    private func makeEngine(maxAttempts: Int = 4) -> SyncEngine {
        let sleeps = sleeps
        return SyncEngine(
            books: repositories.books,
            series: repositories.series,
            sources: repositories.sources,
            files: files,
            retry: RetryPolicy(maxAttempts: maxAttempts, sleep: { await sleeps.record($0) }, jitter: { 1 })
        )
    }

    /// Links `kind` with a fake remote and returns the target to sync.
    private func link(
        _ kind: SourceKind = .dropbox,
        supportsRangedReads: Bool = true
    ) async throws -> (SyncTarget, FakeRemoteSource) {
        let remote = FakeRemoteSource(kind: kind, supportsRangedReads: supportsRangedReads)
        let source = LibrarySource(kind: kind, rootId: "", rootDisplayPath: "/")
        try await repositories.sources.addSource(source)
        return (SyncTarget(source: source, remote: remote), remote)
    }

    private func library(of target: SyncTarget) async throws -> [String: Book] {
        let list = try await repositories.books.books(inSource: target.source.id)
        return Dictionary(uniqueKeysWithValues: list.compactMap { book in book.remoteId.map { ($0, book) } })
    }

    @discardableResult
    private func sync(_ targets: SyncTarget...) async throws -> [LibrarySource.ID: SyncOutcome] {
        try await makeEngine().sync(targets)
    }

    private func finalProgress(_ targets: SyncTarget..., engine: SyncEngine? = nil) async throws -> SyncProgress {
        let engine = engine ?? makeEngine()
        let log = FinalProgress()
        try await engine.sync(targets) { progress in
            if case .finished = progress.phase { log.set(progress) }
        }
        return try #require(log.value)
    }

    // MARK: Listing and diff

    @Test("A first sync finds books in nested folders across pages, reads their metadata, and saves the cursor")
    func firstSync() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.setPageSize(1)
        let earthseaData = try await epub(title: "A Wizard of Earthsea", author: "Ursula K. Le Guin")
        await remote.putFile("/Books/Earthsea.epub", data: earthseaData)
        await remote.putFile("/Books/Fiction/Deep/Tombs.epub", data: try await epub(title: "The Tombs of Atuan"))
        await remote.putFile("/Books/notes.txt")

        let progress = try await finalProgress(target)

        #expect(progress.phase == .finished(.synced))
        #expect(progress.found == 2)
        #expect(progress.toProcess == 2)
        #expect(progress.processed == 2)
        #expect(progress.errors == 0)
        let books = try await library(of: target)
        #expect(books.keys.sorted() == ["/Books/Earthsea.epub", "/Books/Fiction/Deep/Tombs.epub"])
        let earthsea = try #require(books["/Books/Earthsea.epub"])
        #expect(earthsea.title == "A Wizard of Earthsea")
        #expect(earthsea.authorFamily == "Le Guin")
        #expect(earthsea.sourceKind == .dropbox)
        #expect(earthsea.downloadState == .notDownloaded)
        #expect(earthsea.remoteVersion != nil)
        let saved = try #require(try await repositories.sources.source(id: target.source.id))
        #expect(saved.status == .ok)
        #expect(saved.syncCursor != nil)
        #expect(saved.lastSyncedAt != nil)
    }

    @Test("A second sync resumes from the cursor and only reads new or changed books")
    func cursorResume() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.putFile("/A.epub", data: try await epub(title: "A"))
        await remote.putFile("/B.epub", data: try await epub(title: "B"))
        try await sync(target)
        let firstCursor = try await repositories.sources.source(id: target.source.id)?.syncCursor

        await remote.putFile("/C.epub", data: try await epub(title: "C"))
        let progress = try await finalProgress(target)

        #expect(progress.found == 1)
        #expect(progress.toProcess == 1)
        #expect(try await library(of: target).count == 3)
        let cursor = try await repositories.sources.source(id: target.source.id)?.syncCursor
        #expect(cursor != firstCursor)

        // Nothing changed: nothing is read.
        let idle = try await finalProgress(target)
        #expect(idle.found == 0)
        #expect(idle.toProcess == 0)
    }

    @Test("Deleted books are flagged missing, never deleted, and come back when the file returns")
    func deletions() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.putFile("/A.epub", data: try await epub(title: "A"))
        await remote.putFile("/B.epub", data: try await epub(title: "B"))
        await remote.putFile("/C.epub", data: try await epub(title: "C"))
        try await sync(target)
        let a = try #require(try await library(of: target)["/A.epub"])
        try await repositories.bookmarks.addBookmark(Bookmark(bookId: a.id, locatorJSON: "{}", progression: 0.5))

        // Incremental: the source reports the removal.
        await remote.removeFile("/A.epub")
        try await sync(target)
        #expect(try await library(of: target)["/A.epub"]?.isMissingFromSource == true)

        // Full listing (the cursor was rejected): a book that isn't listed is missing.
        await remote.removeFile("/B.epub")
        await remote.invalidateCursors()
        try await sync(target)
        var books = try await library(of: target)
        #expect(books["/B.epub"]?.isMissingFromSource == true)
        #expect(books["/C.epub"]?.isMissingFromSource == false)

        // The same file again: no longer missing, same book, bookmarks kept.
        await remote.putFile("/A.epub", data: try await epub(title: "A"))
        try await sync(target)
        books = try await library(of: target)
        #expect(books["/A.epub"]?.id == a.id)
        #expect(books["/A.epub"]?.isMissingFromSource == false)
        var bookmarks = repositories.bookmarks.observeBookmarks(forBook: a.id).makeAsyncIterator()
        #expect(try await bookmarks.next()?.count == 1)
    }

    @Test("A changed file refreshes metadata, keeps user edits and reading state, and marks a download stale")
    func versionChange() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        let draft = try await epub(title: "Draft Title", author: "First Author")
        let first = await remote.putFile("/Book.epub", data: draft)
        try await sync(target)
        let original = try #require(try await library(of: target)["/Book.epub"])
        #expect(original.remoteVersion == first.version)

        // The user renames the book, downloads it, and reads some of it.
        try await repositories.books.updateBook(id: original.id) { book in
            book.title = "My Title"
            book.userEditedFields = [.title]
            book.isUserEdited = true
            book.downloadState = .downloaded
            book.localFilePath = "Books/remote/\(book.id).epub"
            book.localFileVersion = book.remoteVersion
            book.progression = 0.4
        }

        let final = try await epub(title: "Final Title", author: "Second Author")
        let second = await remote.putFile("/Book.epub", data: final)
        let progress = try await finalProgress(target)
        #expect(progress.toProcess == 1)

        let updated = try #require(try await repositories.books.book(id: original.id))
        #expect(updated.title == "My Title")
        #expect(updated.authorRaw == "Second Author")
        #expect(updated.remoteVersion == second.version)
        #expect(updated.progression == 0.4)
        #expect(updated.downloadState == .downloaded)
        #expect(updated.isDownloadStale)
    }

    @Test("The EPUB's series is saved, unless the user already put the book in one")
    func series() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.putFile("/One.epub", data: try await epub(title: "One", series: ("Earthsea", 1)))
        await remote.putFile("/Two.epub", data: try await epub(title: "Two", series: ("Earthsea", 2)))
        try await sync(target)

        let books = try await library(of: target)
        let one = try #require(books["/One.epub"])
        let entry = try #require(try await repositories.series.series(containing: one.id))
        #expect(entry.series.name == "Earthsea")
        #expect(entry.position == 1)
        let chosen = try await repositories.series.createSeries(named: "Favourites")
        let two = try #require(books["/Two.epub"])
        try await repositories.series.setSeries(chosen.id, position: nil, forBook: two.id)

        await remote.putFile("/Two.epub", data: try await epub(title: "Two, revised", series: ("Earthsea", 2)))
        try await sync(target)
        #expect(try await repositories.series.series(containing: two.id)?.series.id == chosen.id)
    }

    @Test("A file that isn't an EPUB is kept with placeholders and not read again until it changes")
    func unreadable() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.putFile("/Broken.epub", data: Data("not a zip".utf8))

        let progress = try await finalProgress(target)
        #expect(progress.phase == .finished(.synced))
        #expect(progress.unreadable == 1)
        #expect(progress.errors == 0)
        let broken = try #require(try await library(of: target)["/Broken.epub"])
        #expect(broken.title == Placeholders.title)
        #expect(broken.titleIsPlaceholder)

        await remote.invalidateCursors()
        let again = try await finalProgress(target)
        #expect(again.found == 1)
        #expect(again.toProcess == 0)
    }

    @Test("Without ranged reads (iCloud), metadata comes from a temporary full copy")
    func withoutRangedReads() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link(.iCloud, supportsRangedReads: false)
        await remote.putFile("/Books/Earthsea.epub", data: try await epub(title: "A Wizard of Earthsea"))

        try await sync(target)
        #expect(try await library(of: target)["/Books/Earthsea.epub"]?.title == "A Wizard of Earthsea")
        #expect(await remote.downloadCount == 1)
        #expect(await remote.rangeReadCount == 0)
    }

    // MARK: Failures

    @Test("A rate-limited listing is retried after the server's Retry-After")
    func rateLimitRetry() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.putFile("/A.epub", data: try await epub(title: "A"))
        await remote.rateLimitNext(2, retryAfter: 3)

        let progress = try await finalProgress(target)
        #expect(progress.phase == .finished(.synced))
        #expect(await sleeps.delays == [3, 3])
        #expect(await remote.enumerationCount == 3)
        #expect(try await library(of: target).count == 1)
    }

    @Test("Without Retry-After, retries back off exponentially; when they run out the sync fails and keeps the cursor")
    func rateLimitExhausted() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.putFile("/A.epub", data: try await epub(title: "A"))
        try await sync(target)
        let cursor = try await repositories.sources.source(id: target.source.id)?.syncCursor
        await remote.putFile("/B.epub", data: try await epub(title: "B"))
        await remote.rateLimitNext(10)

        let progress = try await finalProgress(target, engine: makeEngine(maxAttempts: 3))
        guard case .finished(.failed(let message)) = progress.phase else {
            Issue.record("expected a failure, got \(progress.phase)")
            return
        }
        #expect(await sleeps.delays == [1, 2])
        let saved = try #require(try await repositories.sources.source(id: target.source.id))
        #expect(saved.status == .error)
        #expect(saved.lastSyncError == message)
        #expect(saved.syncCursor == cursor)
        #expect(try await library(of: target)["/B.epub"] == nil)
    }

    @Test("A listing that fails part-way saves nothing; the next sync picks up everything")
    func failedListingIsIdempotent() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.setPageSize(1)
        await remote.putFile("/A.epub", data: try await epub(title: "A"))
        await remote.putFile("/B.epub", data: try await epub(title: "B"))
        await remote.failEnumeration(afterPages: 1)

        let failed = try await finalProgress(target)
        guard case .finished(.failed) = failed.phase else {
            Issue.record("expected a failure, got \(failed.phase)")
            return
        }
        #expect(try await library(of: target).isEmpty)
        #expect(try await repositories.sources.source(id: target.source.id)?.syncCursor == nil)

        let retried = try await finalProgress(target)
        #expect(retried.phase == .finished(.synced))
        #expect(try await library(of: target).count == 2)
    }

    @Test("Two linked sources sync independently; one losing access doesn't stop the other")
    func twoSources() async throws {
        defer { cleanUp() }
        let (dropbox, dropboxRemote) = try await link(.dropbox)
        let (oneDrive, oneDriveRemote) = try await link(.oneDrive)
        await dropboxRemote.putFile("/Same.epub", data: try await epub(title: "In Dropbox"))
        await oneDriveRemote.putFile("/Same.epub", data: try await epub(title: "In OneDrive"))

        let outcomes = try await makeEngine().sync([dropbox, oneDrive])
        #expect(outcomes == [dropbox.source.id: .synced, oneDrive.source.id: .synced])
        #expect(try await library(of: dropbox)["/Same.epub"]?.title == "In Dropbox")
        #expect(try await library(of: oneDrive)["/Same.epub"]?.title == "In OneDrive")

        await dropboxRemote.expireAuth()
        await oneDriveRemote.putFile("/More.epub", data: try await epub(title: "More"))
        let next = try await makeEngine().sync([dropbox, oneDrive])
        #expect(next == [dropbox.source.id: .needsRelink, oneDrive.source.id: .synced])
        #expect(try await repositories.sources.source(id: dropbox.source.id)?.status == .needsRelink)
        #expect(try await library(of: oneDrive).count == 2)
        #expect(try await library(of: dropbox).count == 1)
    }

    @Test("A cancelled sync changes nothing")
    func cancelled() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.putFile("/A.epub", data: try await epub(title: "A"))
        let engine = makeEngine()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.sync([target])
        }
        #expect(try await task.value == [target.source.id: .cancelled])
        #expect(try await library(of: target).isEmpty)
        let saved = try await repositories.sources.source(id: target.source.id)
        #expect(saved?.status == .ok)
        #expect(saved?.lastSyncedAt == nil)
    }

    @Test("Progress streams listing, then each metadata read, then the outcome")
    func progressStream() async throws {
        defer { cleanUp() }
        let (target, remote) = try await link()
        await remote.putFile("/A.epub", data: try await epub(title: "A"))
        await remote.putFile("/B.epub", data: try await epub(title: "B"))

        var phases: [SyncProgress.Phase] = []
        var last: SyncProgress?
        for await progress in makeEngine().run([target]) {
            if phases.last != progress.phase { phases.append(progress.phase) }
            last = progress
        }
        #expect(phases == [.listing, .fetchingMetadata, .finished(.synced)])
        #expect(last?.processed == 2)
    }

    // MARK: Retry policy

    @Test("Retry delays double from the base, are capped, and a too-long Retry-After gives up")
    func retryDelays() {
        let policy = RetryPolicy(maxAttempts: 6, baseDelay: 1, maxDelay: 5, jitter: { 1 })
        #expect((1...5).map { policy.delay(beforeRetry: $0, retryAfter: nil) } == [1, 2, 4, 5, 5])
        #expect(policy.delay(beforeRetry: 6, retryAfter: nil) == nil)
        #expect(policy.delay(beforeRetry: 1, retryAfter: 2.5) == 2.5)
        #expect(policy.delay(beforeRetry: 1, retryAfter: 120) == nil)
        let jittered = RetryPolicy(baseDelay: 4, jitter: { 0.5 })
        #expect(jittered.delay(beforeRetry: 1, retryAfter: nil) == 2)
    }

    // MARK: Fixtures

    private func epub(title: String, author: String? = nil, series: (String, Double)? = nil) async throws -> Data {
        try await EPUBBytes.make(title: title, author: author, series: series)
    }
}

// MARK: - Helpers

actor SleepLog {
    private(set) var delays: [Double] = []

    func record(_ seconds: Double) {
        delays.append(seconds)
    }
}

/// Holds the last `.finished` progress. Written from the engine's synchronous callback.
final class FinalProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SyncProgress?

    var value: SyncProgress? { lock.withLock { stored } }

    func set(_ progress: SyncProgress) {
        lock.withLock { stored = progress }
    }
}
