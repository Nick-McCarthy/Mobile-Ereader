import Core
import Foundation

// Repository protocols (action plan P1.2). Feature code depends on these, not on GRDB.
// Each `observe…` stream yields the current value immediately, then again whenever the data changes.

/// What the library screen shows: sort order, direction, and search text.
public struct LibraryQuery: Equatable, Sendable {
    public var sort: LibrarySortOrder
    /// Flips the natural direction of `sort` (see `LibrarySortOrder`). Books without a value still come last.
    public var reversed: Bool
    /// Prefix-matched against title, author, series, and collection names. Empty means all books.
    public var searchText: String

    public init(sort: LibrarySortOrder = .recentlyViewed, reversed: Bool = false, searchText: String = "") {
        self.sort = sort
        self.reversed = reversed
        self.searchText = searchText
    }
}

public enum RepositoryError: Error, Equatable, Sendable {
    /// A collection or series name was empty after trimming whitespace.
    case emptyName
    /// Another collection or series already has this name (ignoring case).
    case duplicateName
    /// That service is already linked (v1 allows one folder per service).
    case sourceAlreadyLinked
    /// Local imports have no source row.
    case localIsNotASource
}

public protocol BookRepository: Sendable {
    func observeLibrary(_ query: LibraryQuery) -> AsyncThrowingStream<[Book], any Error>
    func fetchLibrary(_ query: LibraryQuery) async throws -> [Book]
    func book(id: Book.ID) async throws -> Book?
    /// Inserts the book, or updates it if it already exists.
    func save(_ book: Book) async throws
    func deleteBook(id: Book.ID) async throws
    /// Records that the book was opened, for the "Recently viewed" sort.
    func markOpened(id: Book.ID, at date: Date) async throws

    // Sync (P2.7)

    /// Every book of the linked source, missing ones included.
    func books(inSource sourceId: LibrarySource.ID) async throws -> [Book]
    /// Detached books (downloaded books whose source was unlinked), of one kind or, with nil, all of them.
    func detachedBooks(kind: SourceKind?) async throws -> [Book]
    /// Applies what one listing found, in a single transaction.
    func applyListing(_ changes: BookListingChanges) async throws
    /// Reads the book, changes it, and saves it in one transaction, so an edit made meanwhile isn't lost.
    /// Returns the saved book, or nil if there is no book with that id.
    @discardableResult
    func updateBook(id: Book.ID, _ change: @escaping @Sendable (inout Book) -> Void) async throws -> Book?
}

/// What a sync listing changes in a source's books. Metadata is fetched afterwards, book by book.
public struct BookListingChanges: Equatable, Sendable {
    /// Books listed for the first time.
    public var inserted: [Book]
    /// Known books listed again: their path, size, and modified date are updated and they stop being missing.
    public var relisted: [RelistedBook]
    /// Books the source no longer has. They are kept, flagged `isMissingFromSource`.
    public var missing: [Book.ID]
    /// Detached books found again after the service was re-linked: they rejoin the source (`sourceId`), and
    /// are updated like `relisted` ones. See docs/REMOTE_SOURCES.md#unlinking--detached-books.
    public var reattached: [ReattachedBook]

    public init(
        inserted: [Book] = [],
        relisted: [RelistedBook] = [],
        missing: [Book.ID] = [],
        reattached: [ReattachedBook] = []
    ) {
        self.inserted = inserted
        self.relisted = relisted
        self.missing = missing
        self.reattached = reattached
    }

    public var isEmpty: Bool {
        inserted.isEmpty && relisted.isEmpty && missing.isEmpty && reattached.isEmpty
    }
}

/// A detached book that rejoins a re-linked source.
public struct ReattachedBook: Equatable, Sendable {
    public var sourceId: LibrarySource.ID
    public var listing: RelistedBook

    public init(sourceId: LibrarySource.ID, listing: RelistedBook) {
        self.sourceId = sourceId
        self.listing = listing
    }
}

/// What unlinking a source did to its books, so their files can be tidied up afterwards.
public struct SourceUnlinkChanges: Equatable, Sendable {
    /// Books that weren't downloaded: deleted, with their bookmarks, position, memberships and search rows.
    public var removed: [Book]
    /// Downloaded books: kept, with `sourceId` cleared (as stored before the change).
    public var detached: [Book]

    public init(removed: [Book] = [], detached: [Book] = []) {
        self.removed = removed
        self.detached = detached
    }
}

/// A known book seen again in a listing.
public struct RelistedBook: Equatable, Sendable {
    public var id: Book.ID
    public var remotePath: String
    public var fileSize: Int64?
    public var remoteModifiedAt: Date?

    public init(id: Book.ID, remotePath: String, fileSize: Int64?, remoteModifiedAt: Date?) {
        self.id = id
        self.remotePath = remotePath
        self.fileSize = fileSize
        self.remoteModifiedAt = remoteModifiedAt
    }
}

public protocol CollectionRepository: Sendable {
    /// Collections in the user's order.
    func observeCollections() -> AsyncThrowingStream<[BookCollection], any Error>
    func observeBooks(inCollection id: BookCollection.ID) -> AsyncThrowingStream<[Book], any Error>
    func collections(containing bookId: Book.ID) async throws -> [BookCollection]
    /// Creates a collection at the end of the list. Throws `RepositoryError` for empty or duplicate names.
    func createCollection(named name: String) async throws -> BookCollection
    func renameCollection(id: BookCollection.ID, to name: String) async throws
    /// Deletes the collection. Its books stay in the library.
    func deleteCollection(id: BookCollection.ID) async throws
    /// Sets the display order to the order of `ids`.
    func reorderCollections(_ ids: [BookCollection.ID]) async throws
    func addBook(_ bookId: Book.ID, toCollection id: BookCollection.ID) async throws
    func removeBook(_ bookId: Book.ID, fromCollection id: BookCollection.ID) async throws
}

public protocol SeriesRepository: Sendable {
    /// Series sorted by name.
    func observeSeries() -> AsyncThrowingStream<[Series], any Error>
    /// Books in the series, numbered ones first in order, then unnumbered ones by title.
    func observeEntries(inSeries id: Series.ID) -> AsyncThrowingStream<[SeriesEntry], any Error>
    func series(containing bookId: Book.ID) async throws -> (series: Series, position: Double?)?
    /// Throws `RepositoryError` for empty or duplicate names.
    func createSeries(named name: String) async throws -> Series
    /// The series with this name (ignoring case), created if there is none. Throws `RepositoryError.emptyName`.
    func findOrCreateSeries(named name: String) async throws -> Series
    func renameSeries(id: Series.ID, to name: String) async throws
    /// Deletes the series. Its books stay in the library.
    func deleteSeries(id: Series.ID) async throws
    /// Puts the book in a series (replacing any previous one), or removes it when `seriesId` is nil.
    func setSeries(_ seriesId: Series.ID?, position: Double?, forBook bookId: Book.ID) async throws
}

public protocol BookmarkRepository: Sendable {
    /// The book's bookmarks in reading order.
    func observeBookmarks(forBook bookId: Book.ID) -> AsyncThrowingStream<[Bookmark], any Error>
    func addBookmark(_ bookmark: Bookmark) async throws
    func deleteBookmark(id: Bookmark.ID) async throws
}

public protocol LibrarySourceRepository: Sendable {
    /// Linked sources, in `SourceKind` order.
    func observeSources() -> AsyncThrowingStream<[LibrarySource], any Error>
    func source(id: LibrarySource.ID) async throws -> LibrarySource?
    func source(kind: SourceKind) async throws -> LibrarySource?
    /// Records a newly linked source. Throws `RepositoryError.sourceAlreadyLinked` or `.localIsNotASource`.
    func addSource(_ source: LibrarySource) async throws
    /// Points the source at a different folder. Clears the sync cursor, so the next sync is a full listing.
    func changeRoot(
        id: LibrarySource.ID,
        rootId: String?,
        rootBookmark: Data?,
        rootDisplayPath: String
    ) async throws
    /// After a complete sync: saves the cursor, marks the source healthy, and clears any error.
    func recordSyncSuccess(id: LibrarySource.ID, cursor: String?, at date: Date) async throws
    /// After a failed sync. The cursor is left as it was, so the next sync repeats the work.
    func recordSyncFailure(id: LibrarySource.ID, status: SourceStatus, message: String?) async throws
    /// Unlinks the source in one transaction: deletes its books that have no downloaded file, detaches the
    /// rest (`sourceId` set to null), and deletes the source row. Remote files aren't touched. Collections and
    /// series stay, even if they end up empty.
    func unlinkSource(id: LibrarySource.ID) async throws -> SourceUnlinkChanges
}

public protocol ReadingPositionRepository: Sendable {
    func position(forBook bookId: Book.ID) async throws -> ReadingPosition?
    /// Saves where the reader is and updates the book's cached `progression` (0…1) in the same transaction.
    func savePosition(_ position: ReadingPosition, progression: Double) async throws
}
