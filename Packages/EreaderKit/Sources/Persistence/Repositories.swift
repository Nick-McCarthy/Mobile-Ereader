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

public protocol ReadingPositionRepository: Sendable {
    func position(forBook bookId: Book.ID) async throws -> ReadingPosition?
    /// Saves where the reader is and updates the book's cached `progression` (0…1) in the same transaction.
    func savePosition(_ position: ReadingPosition, progression: Double) async throws
}
