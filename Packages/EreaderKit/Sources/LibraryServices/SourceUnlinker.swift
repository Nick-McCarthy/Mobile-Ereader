import BookStorage
import Core
import Foundation
import Persistence
import RemoteSources

/// What the *Unlink* confirmation tells the user before they confirm (UI_SPEC "Book Sources").
public struct UnlinkPreview: Equatable, Sendable {
    /// Books that will be removed from the library because they aren't downloaded.
    public var notDownloaded: Int
    /// Downloaded books that will stay, detached from the service.
    public var downloaded: Int

    public init(notDownloaded: Int, downloaded: Int) {
        self.notDownloaded = notDownloaded
        self.downloaded = downloaded
    }
}

/// Unlinks a book source (action plan P2.10). See docs/REMOTE_SOURCES.md#unlinking--detached-books.
///
/// Remote files are never touched. Books that aren't downloaded are removed from the library; downloaded ones
/// stay as *detached* books, whose file is now the only copy, so it's included in device backups again.
public struct SourceUnlinker: Sendable {
    let books: any BookRepository
    let sources: any LibrarySourceRepository
    let files: BookFileStore
    let downloads: DownloadManager?

    public init(
        books: any BookRepository,
        sources: any LibrarySourceRepository,
        files: BookFileStore,
        downloads: DownloadManager?
    ) {
        self.books = books
        self.sources = sources
        self.files = files
        self.downloads = downloads
    }

    /// The counts for the confirmation: "N books that aren't downloaded will be removed from your library.
    /// M downloaded books will stay."
    public func preview(sourceId: LibrarySource.ID) async throws -> UnlinkPreview {
        let books = try await books.books(inSource: sourceId)
        let downloaded = books.filter { $0.localFilePath != nil }.count
        return UnlinkPreview(notDownloaded: books.count - downloaded, downloaded: downloaded)
    }

    /// Unlinks the source: stops its downloads, signs out of `remote` (revoking where the provider allows and
    /// deleting the Keychain tokens), then removes or detaches its books in one transaction. `remote` is nil
    /// when this version has no adapter for the service; there is then nothing to sign out of.
    @discardableResult
    @concurrent
    public func unlink(
        sourceId: LibrarySource.ID,
        remote: (any RemoteSource)?
    ) async throws -> SourceUnlinkChanges {
        let affected = try await books.books(inSource: sourceId)
        // A download finishing after the unlink would attach a file to a book that is already gone or detached.
        await downloads?.cancelAndWait(affected.map(\.id))
        // Signing out can fail (offline, revoked already). The tokens left behind are deleted at the next launch
        // by `OrphanedTokenCleanup`, since no linked source owns them, so a failure doesn't stop the unlink.
        try? await remote?.unlink()

        let changes = try await sources.unlinkSource(id: sourceId)
        for book in changes.removed {
            if let cover = book.coverPath { try? files.removeCover(atPath: cover) }
        }
        for book in changes.detached {
            if let path = book.localFilePath { try? files.setExcludedFromBackup(false, bookPath: path) }
        }
        return changes
    }
}

/// Removes detached books whose file is gone or unreadable (REMOTE_SOURCES rule 4). A detached book can't be
/// downloaded again, so without its file it's nothing but an empty row. Run at launch, and when opening a book.
public struct DetachedBookCheck: Sendable {
    let books: any BookRepository
    let files: BookFileStore

    public init(books: any BookRepository, files: BookFileStore) {
        self.books = books
        self.files = files
    }

    /// Checks every detached book and returns how many were removed.
    @discardableResult
    @concurrent
    public func run() async throws -> Int {
        var removed = 0
        for book in try await books.detachedBooks(kind: nil) where !hasReadableFile(book) {
            try await remove(book)
            removed += 1
        }
        return removed
    }

    /// Checks one book. Returns true if it was detached without a readable file and has been removed.
    @discardableResult
    public func removeIfFileMissing(_ bookId: Book.ID) async throws -> Bool {
        guard let book = try await books.book(id: bookId), book.isDetached, !hasReadableFile(book) else {
            return false
        }
        try await remove(book)
        return true
    }

    private func hasReadableFile(_ book: Book) -> Bool {
        guard let path = book.localFilePath else { return false }
        return FileManager.default.isReadableFile(atPath: files.url(forBookPath: path).path(percentEncoded: false))
    }

    private func remove(_ book: Book) async throws {
        try await books.deleteBook(id: book.id)
        if let path = book.localFilePath { try? files.removeBook(atPath: path) }
        if let cover = book.coverPath { try? files.removeCover(atPath: cover) }
    }
}
