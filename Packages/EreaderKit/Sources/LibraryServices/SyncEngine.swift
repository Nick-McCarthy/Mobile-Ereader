import BookStorage
import Core
import EPUBMetadata
import Foundation
import Persistence
import RemoteSources

/// A linked source and the adapter that reads it.
public struct SyncTarget: Sendable {
    public var source: LibrarySource
    public var remote: any RemoteSource

    public init(source: LibrarySource, remote: any RemoteSource) {
        self.source = source
        self.remote = remote
    }
}

/// Where one source's sync is, for Settings and the library banner: "Dropbox · found 120 · processed 40".
public struct SyncProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case listing
        case fetchingMetadata
        case finished(SyncOutcome)
    }

    public var sourceId: LibrarySource.ID
    public var kind: SourceKind
    public var phase: Phase
    /// Books the listing returned (for an incremental listing, only the new or changed ones).
    public var found = 0
    /// Books whose metadata has to be read: new ones, and ones whose file changed.
    public var toProcess = 0
    /// Metadata reads finished, failed ones included.
    public var processed = 0
    /// Books that couldn't be read this time and will be retried on the next sync.
    public var errors = 0
    /// Books whose file isn't a readable EPUB. They are kept with placeholders and not retried until they change.
    public var unreadable = 0

    public init(sourceId: LibrarySource.ID, kind: SourceKind, phase: Phase) {
        self.sourceId = sourceId
        self.kind = kind
        self.phase = phase
    }
}

/// How one source's sync ended.
public enum SyncOutcome: Equatable, Sendable {
    /// Everything was processed and the new cursor saved.
    case synced
    /// Some books couldn't be read. Everything else was saved, but not the cursor, so the next sync retries them.
    case incomplete(failedBooks: Int)
    /// Sign-in or folder access was lost. The source is marked `needsRelink`.
    case needsRelink
    /// The listing failed. The message (short, never sensitive) is saved as the source's `lastSyncError`.
    case failed(message: String)
    /// The sync was cancelled. The source's status and cursor are unchanged.
    case cancelled
}

public enum SyncEngineError: Error, Equatable, Sendable {
    /// A sync is already running. Wait for it to finish (it covers every source).
    case alreadySyncing
    /// The listing ended without a cursor.
    case incompleteListing
}

/// Brings the library in line with each linked source (action plan P2.7). Provider-agnostic: it only uses
/// `RemoteSource`. See docs/REMOTE_SOURCES.md#sync-algorithm-syncengine-actor-provider-agnostic.
///
/// For each source in turn: list the books (with retries when rate-limited), apply the diff in one
/// transaction (new books are inserted with placeholders, changed paths updated, vanished books flagged
/// `isMissingFromSource` but never deleted), then read metadata for new and changed books with bounded
/// concurrency, one transaction per book. The cursor is saved only when all of that succeeded.
///
/// Sync is idempotent: a book's `remoteVersion` is only set once its metadata is saved, so after a crash or
/// failure the next sync sees it as changed and reads it again, and books already done are skipped.
public actor SyncEngine {
    let books: any BookRepository
    let series: any SeriesRepository
    let sources: any LibrarySourceRepository
    let files: BookFileStore
    let limits: EPUBLimits
    let retry: RetryPolicy
    let now: @Sendable () -> Date
    private var isSyncing = false

    public init(
        books: any BookRepository,
        series: any SeriesRepository,
        sources: any LibrarySourceRepository,
        files: BookFileStore,
        limits: EPUBLimits = .standard,
        retry: RetryPolicy = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.books = books
        self.series = series
        self.sources = sources
        self.files = files
        self.limits = limits
        self.retry = retry
        self.now = now
    }

    /// Metadata reads at once for a kind of source: fewer for iCloud, whose reads are full-file copies.
    static func metadataConcurrency(for kind: SourceKind) -> Int {
        kind == .iCloud ? 2 : 4
    }

    /// Syncs the targets one after another and streams progress. Ending the stream (or cancelling the task
    /// iterating it) cancels the sync.
    public nonisolated func run(_ targets: [SyncTarget]) -> AsyncStream<SyncProgress> {
        AsyncStream { continuation in
            let task = Task {
                _ = try? await self.sync(targets) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Syncs the targets one after another. One source failing doesn't stop the others.
    /// Throws `SyncEngineError.alreadySyncing` if a sync is running.
    @discardableResult
    public func sync(
        _ targets: [SyncTarget],
        progress: @escaping @Sendable (SyncProgress) -> Void = { _ in }
    ) async throws -> [LibrarySource.ID: SyncOutcome] {
        guard !isSyncing else { throw SyncEngineError.alreadySyncing }
        isSyncing = true
        defer { isSyncing = false }

        var outcomes: [LibrarySource.ID: SyncOutcome] = [:]
        for target in targets {
            if Task.isCancelled {
                outcomes[target.source.id] = .cancelled
                continue
            }
            // Use the saved row: the caller's copy may hold an old cursor, and the source may be unlinked.
            guard let source = try? await sources.source(id: target.source.id) else { continue }
            outcomes[source.id] = await sync(source, using: target.remote, progress: progress)
        }
        return outcomes
    }

    // MARK: One source

    private func sync(
        _ source: LibrarySource,
        using remote: any RemoteSource,
        progress report: @Sendable (SyncProgress) -> Void
    ) async -> SyncOutcome {
        var progress = SyncProgress(sourceId: source.id, kind: source.kind, phase: .listing)
        report(progress)
        let outcome = await syncReportingOutcome(source, remote: remote, progress: &progress, report: report)
        progress.phase = .finished(outcome)
        report(progress)
        return outcome
    }

    private func syncReportingOutcome(
        _ source: LibrarySource,
        remote: any RemoteSource,
        progress: inout SyncProgress,
        report: @Sendable (SyncProgress) -> Void
    ) async -> SyncOutcome {
        do {
            let root = RemoteFolder(id: source.rootId ?? "", name: "", displayPath: source.rootDisplayPath)
            let cursor = source.syncCursor.map(SyncCursor.init)
            let listing = try await retry.run {
                try await Listing.collect(remote.enumerateEPUBs(under: root, since: cursor))
            }
            progress.found = listing.upserts.count

            let detached = try await books.detachedBooks(kind: source.kind)
            let (changes, queue) = try await Self.diff(
                listing,
                against: books.books(inSource: source.id),
                detached: detached,
                source: source,
                dateAdded: now()
            )
            try await books.applyListing(changes)
            // A re-attached download can be fetched again, so it leaves device backups once more.
            let detachedPaths = Dictionary(uniqueKeysWithValues: detached.map { ($0.id, $0.localFilePath) })
            for book in changes.reattached {
                if let path = detachedPaths[book.listing.id] ?? nil {
                    try? files.setExcludedFromBackup(true, bookPath: path)
                }
            }
            progress.toProcess = queue.count
            progress.phase = .fetchingMetadata
            report(progress)

            try await fetchMetadata(queue, from: remote, kind: source.kind, progress: &progress, report: report)
            try Task.checkCancellation()

            if progress.errors > 0 {
                try await sources.recordSyncFailure(
                    id: source.id,
                    status: .error,
                    message: SyncMessages.someBooksFailed
                )
                return .incomplete(failedBooks: progress.errors)
            }
            try await sources.recordSyncSuccess(id: source.id, cursor: listing.cursor.rawValue, at: now())
            return .synced
        } catch {
            if Task.isCancelled || error is CancellationError { return .cancelled }
            if case RemoteSourceError.needsRelink = error {
                try? await sources.recordSyncFailure(
                    id: source.id,
                    status: .needsRelink,
                    message: SyncMessages.needsRelink
                )
                return .needsRelink
            }
            let message = SyncMessages.message(for: error)
            try? await sources.recordSyncFailure(id: source.id, status: .error, message: message)
            return .failed(message: message)
        }
    }

    // MARK: Diff

    /// A book whose metadata has to be (re)read, and the listed file to read it from.
    struct MetadataJob: Equatable, Sendable {
        var bookId: Book.ID
        var file: RemoteFile
    }

    /// What the listing changes in the source's books, and which of them need metadata.
    ///
    /// A listed file that matches a detached book of the same kind (by `remoteId`; for iCloud, whose ids are
    /// paths, also by `remoteVersion`) re-attaches that book instead of adding a new one, so its bookmarks and
    /// progress survive a re-link.
    static func diff(
        _ listing: Listing,
        against existing: [Book],
        detached: [Book] = [],
        source: LibrarySource,
        dateAdded: Date
    ) -> (BookListingChanges, [MetadataJob]) {
        var byRemoteId: [String: Book] = [:]
        for book in existing {
            if let remoteId = book.remoteId { byRemoteId[remoteId] = book }
        }
        var detachedByRemoteId: [String: Book] = [:]
        for book in detached where book.sourceKind == source.kind {
            if let remoteId = book.remoteId { detachedByRemoteId[remoteId] = book }
        }

        var changes = BookListingChanges()
        var queue: [MetadataJob] = []
        // Sorted so books are read in path order, and tests are deterministic.
        for file in listing.upserts.values.sorted(by: { $0.displayPath < $1.displayPath }) {
            if let book = byRemoteId[file.remoteId] {
                let moved =
                    book.remotePath != file.displayPath || book.fileSize != file.size
                    || book.remoteModifiedAt != file.modifiedAt
                if moved || book.isMissingFromSource {
                    changes.relisted.append(
                        RelistedBook(
                            id: book.id,
                            remotePath: file.displayPath,
                            fileSize: file.size,
                            remoteModifiedAt: file.modifiedAt
                        )
                    )
                }
                if book.remoteVersion != file.version {
                    queue.append(MetadataJob(bookId: book.id, file: file))
                }
            } else if let book = detachedByRemoteId.removeValue(forKey: file.remoteId),
                source.kind != .iCloud || book.remoteVersion == file.version
            {
                let listing = RelistedBook(
                    id: book.id,
                    remotePath: file.displayPath,
                    fileSize: file.size,
                    remoteModifiedAt: file.modifiedAt
                )
                changes.reattached.append(ReattachedBook(sourceId: source.id, listing: listing))
                if book.remoteVersion != file.version {
                    queue.append(MetadataJob(bookId: book.id, file: file))
                }
            } else {
                var book = Book(sourceKind: source.kind, title: nil, authorRaw: nil, dateAdded: dateAdded)
                book.sourceId = source.id
                book.remoteId = file.remoteId
                book.remotePath = file.displayPath
                book.fileSize = file.size
                book.remoteModifiedAt = file.modifiedAt
                // remoteVersion stays nil until the metadata is saved: see the type's documentation.
                changes.inserted.append(book)
                queue.append(MetadataJob(bookId: book.id, file: file))
            }
        }

        var gone = listing.removed
        if listing.isFull {
            gone.formUnion(byRemoteId.keys.filter { listing.upserts[$0] == nil })
        }
        changes.missing = gone.sorted().compactMap { remoteId in
            guard let book = byRemoteId[remoteId], !book.isMissingFromSource else { return nil }
            return book.id
        }
        return (changes, queue)
    }

    // MARK: Metadata

    private enum FetchOutcome: Sendable {
        case saved
        case unreadable
        case failed
    }

    /// What a metadata read needs, bundled so the child tasks don't touch the actor.
    private struct FetchContext: Sendable {
        var remote: any RemoteSource
        var books: any BookRepository
        var series: any SeriesRepository
        var files: BookFileStore
        var limits: EPUBLimits
        var retry: RetryPolicy
    }

    private func fetchMetadata(
        _ queue: [MetadataJob],
        from remote: any RemoteSource,
        kind: SourceKind,
        progress: inout SyncProgress,
        report: @Sendable (SyncProgress) -> Void
    ) async throws {
        guard !queue.isEmpty else { return }
        let context = FetchContext(
            remote: remote,
            books: books,
            series: series,
            files: files,
            limits: limits,
            retry: retry
        )
        var pending = queue[...]
        try await withThrowingTaskGroup(of: FetchOutcome.self) { group in
            for _ in 0..<min(Self.metadataConcurrency(for: kind), pending.count) {
                let job = pending.removeFirst()
                group.addTask { try await Self.fetch(job, context) }
            }
            while let outcome = try await group.next() {
                progress.processed += 1
                switch outcome {
                case .saved: break
                case .unreadable: progress.unreadable += 1
                case .failed: progress.errors += 1
                }
                report(progress)
                if let job = pending.popFirst() {
                    group.addTask { try await Self.fetch(job, context) }
                }
            }
        }
    }

    /// Reads one book's metadata and saves it. Throws only for errors that stop the whole sync: cancellation
    /// and lost access. Anything else is counted, and the book is retried on the next sync.
    @concurrent
    private static func fetch(_ job: MetadataJob, _ context: FetchContext) async throws -> FetchOutcome {
        let metadata: EPUBMetadata
        do {
            metadata = try await context.retry.run {
                try await Self.readMetadata(of: job.file, from: context.remote, limits: context.limits)
            }
        } catch let error as RemoteSourceError where error == .needsRelink {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch is EPUBMetadataError {
            // Not a readable EPUB. Keep the book with what it has and don't retry until the file changes.
            try await context.books.updateBook(id: job.bookId) { book in
                book.remoteVersion = job.file.version
            }
            return .unreadable
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return .failed
        }

        // The cover is written before the transaction. Sync covers are always `<bookId>.jpg`; a cover the
        // user chose is stored under another name, so this never overwrites it.
        let coverPath = metadata.coverThumbnail.flatMap { try? context.files.saveCover($0, bookId: job.bookId) }
        do {
            try await context.books.updateBook(id: job.bookId) { book in
                Self.apply(metadata, coverPath: coverPath, file: job.file, to: &book)
            }
        } catch {
            return .failed
        }
        // Like a local import: the EPUB's series is used unless the user already put the book in one.
        try? await Self.saveSeries(from: metadata, forBook: job.bookId, series: context.series)
        return .saved
    }

    /// Ranged reads where the provider supports them; otherwise (iCloud) the file is copied to a temporary
    /// folder, parsed, and deleted.
    @concurrent
    private static func readMetadata(
        of file: RemoteFile,
        from remote: any RemoteSource,
        limits: EPUBLimits
    ) async throws -> EPUBMetadata {
        if let reader = remote.byteRangeReader(for: file) {
            return try await EPUBMetadataReader.read(remote: reader, limits: limits) { destination in
                try await remote.download(file, to: destination, progress: { _ in })
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("book.epub")
        try await remote.download(file, to: copy, progress: { _ in })
        return try await EPUBMetadataReader.read(fileAt: copy, limits: limits)
    }

    /// Updates the book from fresh metadata. Fields the user edited are kept, and so are the book's id, reading
    /// state, download, and memberships. Setting `remoteVersion` marks the book as up to date with the source;
    /// a downloaded copy of an older version then reports `isDownloadStale`.
    static func apply(_ metadata: EPUBMetadata, coverPath: String?, file: RemoteFile, to book: inout Book) {
        let fresh = LocalBookImporter.makeBook(id: book.id, metadata: metadata)
        let edited = Set(book.userEditedFields)
        if !edited.contains(.title) {
            book.title = fresh.title
            book.titleSort = fresh.titleSort
            book.titleIsPlaceholder = fresh.titleIsPlaceholder
        }
        if !edited.contains(.author) {
            book.authorRaw = fresh.authorRaw
            book.authorIsPlaceholder = fresh.authorIsPlaceholder
            book.authorFileAs = fresh.authorFileAs
            book.authorStoredFormat = fresh.authorStoredFormat
            book.authorGiven = fresh.authorGiven
            book.authorFamily = fresh.authorFamily
        }
        if !edited.contains(.publicationDate) {
            book.publicationDate = fresh.publicationDate
            book.publicationDateSort = fresh.publicationDateSort
        }
        // A new version without a cover keeps the old one rather than falling back to a placeholder.
        if !edited.contains(.cover), let coverPath {
            book.coverPath = coverPath
        }
        book.language = fresh.language
        book.publisher = fresh.publisher
        book.description = fresh.description
        book.identifier = fresh.identifier
        book.remotePath = file.displayPath
        book.fileSize = file.size
        book.remoteModifiedAt = file.modifiedAt
        book.remoteVersion = file.version
        book.isMissingFromSource = false
    }

    private static func saveSeries(
        from metadata: EPUBMetadata,
        forBook bookId: Book.ID,
        series: any SeriesRepository
    ) async throws {
        guard let name = metadata.seriesName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            try await series.series(containing: bookId) == nil
        else { return }
        let found = try await series.findOrCreateSeries(named: name)
        try await series.setSeries(found.id, position: metadata.seriesPosition, forBook: bookId)
    }
}

// MARK: - Listing

/// Everything one `enumerateEPUBs` stream reported, folded together.
struct Listing: Equatable, Sendable {
    /// True if the stream sent `.reset`: books not in `upserts` are missing from the source.
    var isFull = false
    var upserts: [String: RemoteFile] = [:]
    var removed: Set<String> = []
    var cursor: SyncCursor

    /// Reads the whole stream. Throws if it fails, or ends without a cursor (an incomplete listing).
    @concurrent
    static func collect(_ stream: RemoteChangeStream) async throws -> Listing {
        var isFull = false
        var upserts: [String: RemoteFile] = [:]
        var removed: Set<String> = []
        var cursor: SyncCursor?
        for try await change in stream {
            switch change {
            case .reset:
                isFull = true
                upserts.removeAll()
                removed.removeAll()
            case .upsert(let file):
                upserts[file.remoteId] = file
                removed.remove(file.remoteId)
            case .removed(let remoteId):
                removed.insert(remoteId)
                upserts[remoteId] = nil
            case .cursor(let value):
                cursor = value
            }
        }
        // A stream ends early, without throwing, when the task is cancelled.
        try Task.checkCancellation()
        guard let cursor else { throw SyncEngineError.incompleteListing }
        return Listing(isFull: isFull, upserts: upserts, removed: removed, cursor: cursor)
    }
}

// MARK: - Messages

/// Short messages saved as `lastSyncError` and shown in Settings. They never include paths, names, or
/// provider responses.
enum SyncMessages {
    static let someBooksFailed = "Some books couldn't be read. Sync again to retry them."
    static let needsRelink = "Sign in again to keep syncing."
    static let busy = "The service is busy. Sync again in a few minutes."
    static let folderMissing = "The book folder can't be found. Choose it again."
    static let other = "Sync didn't finish. Check your connection and try again."

    static func message(for error: any Error) -> String {
        switch error {
        case RemoteSourceError.rateLimited: busy
        case RemoteSourceError.notFound: folderMissing
        default: other
        }
    }
}
