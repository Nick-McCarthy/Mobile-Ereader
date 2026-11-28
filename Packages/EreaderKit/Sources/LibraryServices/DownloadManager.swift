import BookStorage
import Core
import Foundation
import Persistence
import RemoteSources

public enum DownloadError: Error, Equatable, Sendable {
    /// There is no book with that id.
    case bookNotFound
    /// The book can't be downloaded: it's a local import, or a detached book whose source was unlinked.
    case notDownloadable
    /// The downloaded file isn't the size the last sync reported, so the file probably changed. Sync and retry.
    case sizeMismatch(expected: Int64, actual: Int64?)
}

/// What *Remove Download* did.
public enum RemoveDownloadOutcome: Equatable, Sendable {
    /// The file was deleted; the book stays, with its bookmarks and progress, and can be downloaded again.
    case removed
    /// The book was detached (its source unlinked), so the file was its only copy: the book was removed from
    /// the library. See docs/REMOTE_SOURCES.md#unlinking--detached-books.
    case removedFromLibrary
    /// Nothing was downloaded.
    case nothingToRemove
}

/// Downloads remote books on demand and removes them again (action plan P2.9).
/// See docs/REMOTE_SOURCES.md#downloading-a-book-tap-in-library.
///
/// The file is written to `Books/remote/<bookId>.partial`, its size checked against the last sync, then renamed
/// to `<bookId>.epub` (replacing an out-of-date copy in one step) with Data Protection and backup exclusion.
/// `downloadState` is `downloading` meanwhile; afterwards it is `downloaded`, or `failed` (or what it was, if
/// cancelled). A second request for a book already downloading joins the first.
public actor DownloadManager {
    let books: any BookRepository
    let files: BookFileStore
    let retry: RetryPolicy
    private var tasks: [Book.ID: Task<Book, any Error>] = [:]
    private let progressCenter = DownloadProgressCenter()

    public init(books: any BookRepository, files: BookFileStore, retry: RetryPolicy = .standard) {
        self.books = books
        self.files = files
        self.retry = retry
    }

    /// The progress (0…1) of every running download, now and after each change.
    public nonisolated func observeProgress() -> AsyncStream<[Book.ID: Double]> {
        progressCenter.stream()
    }

    public func isDownloading(_ bookId: Book.ID) -> Bool {
        tasks[bookId] != nil
    }

    /// Downloads the book from `remote` (the adapter for the book's source) and returns it as saved.
    /// A book that is downloaded and up to date is returned as it is.
    @discardableResult
    public func download(_ bookId: Book.ID, from remote: any RemoteSource) async throws -> Book {
        if let running = tasks[bookId] {
            return try await running.value
        }
        guard let book = try await books.book(id: bookId) else { throw DownloadError.bookNotFound }
        if book.downloadState == .downloaded, book.localFilePath != nil, !book.isDownloadStale {
            return book
        }
        guard let file = Self.remoteFile(for: book) else { throw DownloadError.notDownloadable }

        let job = Job(book: book, file: file, remote: remote, books: books, files: files, retry: retry)
        let center = progressCenter
        let task = Task { try await Self.run(job, progress: center) }
        tasks[bookId] = task
        defer { tasks[bookId] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stops the book's download, if one is running. The book goes back to the state it was in.
    public func cancel(_ bookId: Book.ID) {
        tasks[bookId]?.cancel()
    }

    /// Deletes the book's downloaded file (cancelling a running download first). A detached book can't be
    /// downloaded again, so it is removed from the library along with its file and cover; the UI must have
    /// asked first (UI_SPEC "Remove Download & Book").
    @discardableResult
    public func removeDownload(_ bookId: Book.ID) async throws -> RemoveDownloadOutcome {
        if let running = tasks[bookId] {
            running.cancel()
            _ = try? await running.value
        }
        guard let book = try await books.book(id: bookId) else { throw DownloadError.bookNotFound }
        guard book.sourceKind != .local else { throw DownloadError.notDownloadable }

        if book.isDetached {
            try await books.deleteBook(id: bookId)
            if let path = book.localFilePath { try? files.removeBook(atPath: path) }
            if let cover = book.coverPath { try? files.removeCover(atPath: cover) }
            return .removedFromLibrary
        }
        guard let path = book.localFilePath else { return .nothingToRemove }
        // The database first, so it never points at a file that's gone.
        try await books.updateBook(id: bookId) { book in
            book.localFilePath = nil
            book.localFileVersion = nil
            book.downloadState = .notDownloaded
        }
        try? files.removeBook(atPath: path)
        return .removed
    }

    // MARK: Running a download

    private struct Job: Sendable {
        var book: Book
        var file: RemoteFile
        var remote: any RemoteSource
        var books: any BookRepository
        var files: BookFileStore
        var retry: RetryPolicy
    }

    /// The `RemoteFile` the last sync saw for this book, or nil if it has no source to download from.
    static func remoteFile(for book: Book) -> RemoteFile? {
        guard book.sourceKind != .local, book.sourceId != nil, let remoteId = book.remoteId else { return nil }
        let path = book.remotePath ?? remoteId
        return RemoteFile(
            remoteId: remoteId,
            displayPath: path,
            name: String(path.split(separator: "/").last ?? Substring(path)),
            size: book.fileSize,
            version: book.remoteVersion ?? "",
            modifiedAt: book.remoteModifiedAt
        )
    }

    @concurrent
    private static func run(_ job: Job, progress center: DownloadProgressCenter) async throws -> Book {
        let bookId = job.book.id
        let previousState = job.book.downloadState
        try await job.books.updateBook(id: bookId) { $0.downloadState = .downloading }
        center.update(bookId, 0)
        defer { center.finish(bookId) }

        let partial: URL
        do {
            partial = try job.files.partialDownloadURL(bookId: bookId)
        } catch {
            try? await job.books.updateBook(id: bookId) { $0.downloadState = .failed }
            throw error
        }
        do {
            try? FileManager.default.removeItem(at: partial)
            try await job.retry.run {
                try await job.remote.download(job.file, to: partial) { fraction in
                    center.update(bookId, min(max(fraction, 0), 1))
                }
            }
            try Task.checkCancellation()
            let actual = BookFileStore.size(of: partial)
            if let expected = job.file.size, actual != expected {
                throw DownloadError.sizeMismatch(expected: expected, actual: actual)
            }
            let path = try job.files.commitDownload(from: partial, bookId: bookId)
            // The version the download started at: if a sync moved it on meanwhile, the copy is already stale.
            let version = job.book.remoteVersion
            let saved = try await job.books.updateBook(id: bookId) { book in
                book.localFilePath = path
                book.localFileVersion = version
                book.downloadState = .downloaded
            }
            guard let saved else {
                // The book was deleted while downloading.
                try? job.files.removeBook(atPath: path)
                throw DownloadError.bookNotFound
            }
            return saved
        } catch {
            try? FileManager.default.removeItem(at: partial)
            let cancelled = error is CancellationError || Task.isCancelled
            // A cancelled update of a stale copy keeps that copy; it's still readable.
            let state: DownloadState = cancelled ? previousState : .failed
            try? await job.books.updateBook(id: bookId) { book in
                book.downloadState = book.localFilePath == nil ? state : .downloaded
            }
            if cancelled { throw CancellationError() }
            throw error
        }
    }
}

/// Progress of running downloads, shared with the adapters' progress callbacks (which run on any thread).
final class DownloadProgressCenter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [Book.ID: Double] = [:]
    private var continuations: [UUID: AsyncStream<[Book.ID: Double]>.Continuation] = [:]

    func stream() -> AsyncStream<[Book.ID: Double]> {
        let (stream, continuation) = AsyncStream<[Book.ID: Double]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.withLock {
            continuations[id] = continuation
            continuation.yield(progress)
        }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func update(_ bookId: Book.ID, _ fraction: Double) {
        lock.withLock {
            progress[bookId] = fraction
            for continuation in continuations.values { continuation.yield(progress) }
        }
    }

    func finish(_ bookId: Book.ID) {
        lock.withLock {
            progress[bookId] = nil
            for continuation in continuations.values { continuation.yield(progress) }
        }
    }
}
