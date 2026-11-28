import BookStorage
import Core
import Foundation
import Persistence
import RemoteSources

/// What tapping a book did (action plan P3.5, docs/UI_SPEC.md#library).
public enum BookTapResult: Equatable, Sendable {
    /// Open the reader on this book; it is downloaded and marked opened.
    case open(Book)
    /// The tap stopped the book's running download, or a later tap did.
    case cancelled
    /// Nothing to open; tell the user why.
    case failed(BookOpenError)
}

/// Why a tapped book couldn't be opened, in terms the library can explain.
public enum BookOpenError: Error, Equatable, Sendable {
    /// There's no connection, so the book can't be downloaded now.
    case offline
    /// The source's sign-in or folder access is gone; link it again in Settings.
    case needsRelink
    /// The file is no longer in the linked folder.
    case missingFromSource
    /// The file changed in its source since the last sync; sync and try again.
    case changedInSource
    /// This version can't download from the book's source (its adapter isn't available yet, or the source was
    /// unlinked and the book has no downloaded copy).
    case notDownloadable
    /// The downloaded copy is missing from the device and can't be downloaded again.
    case fileMissing
    /// Anything else: the download failed.
    case downloadFailed

    /// The library's explanation for a download that threw `error`.
    public static func from(_ error: any Error) -> BookOpenError {
        switch error {
        case let error as BookOpenError: return error
        case RemoteSourceError.needsRelink: return .needsRelink
        case RemoteSourceError.notFound: return .missingFromSource
        case DownloadError.sizeMismatch: return .changedInSource
        case DownloadError.notDownloadable, DownloadError.bookNotFound: return .notDownloadable
        case let error as URLError where offlineCodes.contains(error.code): return .offline
        default: return .downloadFailed
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
        .cannotFindHost, .cannotConnectToHost, .timedOut,
    ]
}

/// Tapping a book in the library: open it if it's downloaded, otherwise download it and then open it; tapping
/// a book that is downloading cancels the download. A downloaded copy that changed in its source is downloaded
/// again first, but opened as it is if that fails, so an out-of-date book still reads offline.
public struct BookOpener: Sendable {
    let books: any BookRepository
    let sources: any LibrarySourceRepository
    let files: BookFileStore
    let downloads: DownloadManager
    let remote: @Sendable (LibrarySource) -> (any RemoteSource)?
    let now: @Sendable () -> Date

    /// `remote` gives the adapter for a source, or nil if this version can't read it (`BookSources.remote(for:)`).
    public init(
        books: any BookRepository,
        sources: any LibrarySourceRepository,
        files: BookFileStore,
        downloads: DownloadManager,
        remote: @escaping @Sendable (LibrarySource) -> (any RemoteSource)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.books = books
        self.sources = sources
        self.files = files
        self.downloads = downloads
        self.remote = remote
        self.now = now
    }

    public func tap(_ bookId: Book.ID) async -> BookTapResult {
        if await downloads.isDownloading(bookId) {
            await downloads.cancel(bookId)
            return .cancelled
        }
        do {
            guard let book = try await books.book(id: bookId) else { return .failed(.notDownloadable) }
            let ready = try await readyToRead(book)
            try await books.markOpened(id: bookId, at: now())
            return .open(try await books.book(id: bookId) ?? ready)
        } catch is CancellationError {
            return .cancelled
        } catch let error as BookOpenError {
            return .failed(error)
        } catch {
            return Task.isCancelled ? .cancelled : .failed(.from(error))
        }
    }

    /// The book with a readable file, downloading it if it has none or (if possible) if it's out of date.
    private func readyToRead(_ book: Book) async throws -> Book {
        let hasFile = book.downloadState == .downloaded && hasReadableFile(book)
        if hasFile, !book.isDownloadStale { return book }
        if book.sourceKind == .local || book.isDetached {
            if hasFile { return book }
            throw BookOpenError.fileMissing
        }
        do {
            guard let sourceId = book.sourceId, let source = try await sources.source(id: sourceId),
                let remote = remote(source)
            else { throw BookOpenError.notDownloadable }
            return try await downloads.download(book.id, from: remote)
        } catch {
            // Read the out-of-date copy rather than nothing, unless the user cancelled.
            if hasFile, !(error is CancellationError), !Task.isCancelled { return book }
            throw error
        }
    }

    private func hasReadableFile(_ book: Book) -> Bool {
        guard let path = book.localFilePath else { return false }
        return FileManager.default.fileExists(atPath: files.url(forBookPath: path).path(percentEncoded: false))
    }
}
