import Core
import Foundation
import GRDB

/// The GRDB-backed implementations of every repository, ready to put in the app environment.
public struct DatabaseRepositories: Sendable {
    public let books: any BookRepository
    public let collections: any CollectionRepository
    public let series: any SeriesRepository
    public let bookmarks: any BookmarkRepository
    public let readingPositions: any ReadingPositionRepository
    public let sources: any LibrarySourceRepository

    public init(database: AppDatabase) {
        books = DatabaseBookRepository(database: database)
        collections = DatabaseCollectionRepository(database: database)
        series = DatabaseSeriesRepository(database: database)
        bookmarks = DatabaseBookmarkRepository(database: database)
        readingPositions = DatabaseReadingPositionRepository(database: database)
        sources = DatabaseLibrarySourceRepository(database: database)
    }
}

// MARK: - Books

public struct DatabaseBookRepository: BookRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func observeLibrary(_ query: LibraryQuery) -> AsyncThrowingStream<[Book], any Error> {
        database.observe { db in try Self.library(db, query) }
    }

    public func fetchLibrary(_ query: LibraryQuery) async throws -> [Book] {
        try await database.writer.read { db in try Self.library(db, query) }
    }

    public func book(id: Book.ID) async throws -> Book? {
        try await database.writer.read { db in try Book.fetchOne(db, key: id) }
    }

    public func save(_ book: Book) async throws {
        try await database.writer.write { db in try book.save(db) }
    }

    public func deleteBook(id: Book.ID) async throws {
        try await database.writer.write { db in _ = try Book.deleteOne(db, key: id) }
    }

    public func markOpened(id: Book.ID, at date: Date) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE book SET lastOpenedAt = ? WHERE id = ?", arguments: [date, id])
        }
    }

    public func books(inSource sourceId: LibrarySource.ID) async throws -> [Book] {
        try await database.writer.read { db in
            try Book.fetchAll(db, sql: "SELECT * FROM book WHERE sourceId = ?", arguments: [sourceId])
        }
    }

    public func detachedBooks(kind: SourceKind?) async throws -> [Book] {
        try await database.writer.read { db in
            if let kind {
                return try Book.fetchAll(
                    db,
                    sql: "SELECT * FROM book WHERE sourceId IS NULL AND sourceKind = ?",
                    arguments: [kind.rawValue]
                )
            }
            return try Book.fetchAll(db, sql: "SELECT * FROM book WHERE sourceId IS NULL AND sourceKind != 'local'")
        }
    }

    public func applyListing(_ changes: BookListingChanges) async throws {
        guard !changes.isEmpty else { return }
        try await database.writer.write { db in
            for book in changes.inserted {
                try book.insert(db)
            }
            for book in changes.relisted {
                try db.execute(
                    sql: """
                        UPDATE book SET remotePath = ?, fileSize = ?, remoteModifiedAt = ?, isMissingFromSource = 0
                        WHERE id = ?
                        """,
                    arguments: [book.remotePath, book.fileSize, book.remoteModifiedAt, book.id]
                )
            }
            for id in changes.missing {
                try db.execute(sql: "UPDATE book SET isMissingFromSource = 1 WHERE id = ?", arguments: [id])
            }
            for book in changes.reattached {
                let listing = book.listing
                try db.execute(
                    sql: """
                        UPDATE book
                        SET sourceId = ?, remotePath = ?, fileSize = ?, remoteModifiedAt = ?, isMissingFromSource = 0
                        WHERE id = ?
                        """,
                    arguments: [
                        book.sourceId, listing.remotePath, listing.fileSize, listing.remoteModifiedAt, listing.id,
                    ]
                )
            }
        }
    }

    @discardableResult
    public func updateBook(id: Book.ID, _ change: @escaping @Sendable (inout Book) -> Void) async throws -> Book? {
        try await database.writer.write { db in
            guard var book = try Book.fetchOne(db, key: id) else { return nil }
            change(&book)
            book.id = id
            try book.update(db)
            return book
        }
    }

    static func library(_ db: Database, _ query: LibraryQuery) throws -> [Book] {
        let order = orderClause(query.sort, reversed: query.reversed)
        let searchText = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchText.isEmpty {
            return try Book.fetchAll(db, sql: "SELECT * FROM book ORDER BY \(order)")
        }
        // Built by GRDB from the user's words, so quotes or operators in the input can't break the query.
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: searchText) else { return [] }
        return try Book.fetchAll(
            db,
            sql: """
                SELECT * FROM book
                WHERE id IN (SELECT bookId FROM book_fts WHERE book_fts MATCH ?)
                ORDER BY \(order)
                """,
            arguments: [pattern]
        )
    }

    /// ORDER BY for each sort option (docs/DATA_MODEL.md#display-rules). Missing values always sort last.
    static func orderClause(_ sort: LibrarySortOrder, reversed: Bool) -> String {
        let forward = reversed ? "DESC" : "ASC"
        let backward = reversed ? "ASC" : "DESC"
        switch sort {
        case .recentlyViewed:
            return "lastOpenedAt IS NULL, lastOpenedAt \(backward), dateAdded \(backward)"
        case .title:
            return "titleIsPlaceholder, titleSort \(forward)"
        case .author:
            return """
                authorIsPlaceholder, ifnull(authorFamily, authorRaw) COLLATE NOCASE \(forward), \
                authorGiven COLLATE NOCASE \(forward), titleSort
                """
        case .publicationDate:
            return "publicationDateSort IS NULL, publicationDateSort \(forward), titleSort"
        case .downloadState:
            return "downloadState = 'downloaded' \(backward), titleSort"
        }
    }
}

// MARK: - Collections

public struct DatabaseCollectionRepository: CollectionRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func observeCollections() -> AsyncThrowingStream<[BookCollection], any Error> {
        database.observe { db in
            try BookCollection.fetchAll(db, sql: "SELECT * FROM collection ORDER BY sortOrder, name")
        }
    }

    public func observeBooks(inCollection id: BookCollection.ID) -> AsyncThrowingStream<[Book], any Error> {
        database.observe { db in
            try Book.fetchAll(
                db,
                sql: """
                    SELECT b.* FROM book b JOIN collection_book cb ON cb.bookId = b.id
                    WHERE cb.collectionId = ?
                    ORDER BY b.titleIsPlaceholder, b.titleSort
                    """,
                arguments: [id]
            )
        }
    }

    public func observeMemberships() -> AsyncThrowingStream<CollectionMemberships, any Error> {
        database.observe { db in
            let collections = try BookCollection.fetchAll(db, sql: "SELECT * FROM collection ORDER BY sortOrder, name")
            var bookIds: [BookCollection.ID: Set<Book.ID>] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT collectionId, bookId FROM collection_book")
            for row in rows {
                let collectionId: String = row["collectionId"]
                let bookId: String = row["bookId"]
                bookIds[collectionId, default: []].insert(bookId)
            }
            return CollectionMemberships(collections: collections, bookIds: bookIds)
        }
    }

    public func collections(containing bookId: Book.ID) async throws -> [BookCollection] {
        try await database.writer.read { db in
            try BookCollection.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM collection c JOIN collection_book cb ON cb.collectionId = c.id
                    WHERE cb.bookId = ?
                    ORDER BY c.sortOrder, c.name
                    """,
                arguments: [bookId]
            )
        }
    }

    public func createCollection(named name: String) async throws -> BookCollection {
        let name = try validatedName(name)
        return try await mappingDuplicateName {
            try await database.writer.write { db in
                let next = try Int.fetchOne(db, sql: "SELECT ifnull(max(sortOrder) + 1, 0) FROM collection") ?? 0
                let collection = BookCollection(name: name, sortOrder: next)
                try collection.insert(db)
                return collection
            }
        }
    }

    public func renameCollection(id: BookCollection.ID, to name: String) async throws {
        let name = try validatedName(name)
        try await mappingDuplicateName {
            try await database.writer.write { db in
                try db.execute(sql: "UPDATE collection SET name = ? WHERE id = ?", arguments: [name, id])
            }
        }
    }

    public func deleteCollection(id: BookCollection.ID) async throws {
        try await database.writer.write { db in _ = try BookCollection.deleteOne(db, key: id) }
    }

    public func reorderCollections(_ ids: [BookCollection.ID]) async throws {
        try await database.writer.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE collection SET sortOrder = ? WHERE id = ?", arguments: [index, id])
            }
        }
    }

    public func addBook(_ bookId: Book.ID, toCollection id: BookCollection.ID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO collection_book (collectionId, bookId) VALUES (?, ?)",
                arguments: [id, bookId]
            )
        }
    }

    public func removeBook(_ bookId: Book.ID, fromCollection id: BookCollection.ID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM collection_book WHERE collectionId = ? AND bookId = ?",
                arguments: [id, bookId]
            )
        }
    }
}

// MARK: - Series

public struct DatabaseSeriesRepository: SeriesRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func observeSeries() -> AsyncThrowingStream<[Series], any Error> {
        database.observe { db in try Series.fetchAll(db, sql: "SELECT * FROM series ORDER BY name") }
    }

    public func observeEntries(inSeries id: Series.ID) -> AsyncThrowingStream<[SeriesEntry], any Error> {
        database.observe { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT b.*, sb.position AS seriesPosition
                    FROM book b JOIN series_book sb ON sb.bookId = b.id
                    WHERE sb.seriesId = ?
                    ORDER BY sb.position IS NULL, sb.position, b.titleSort
                    """,
                arguments: [id]
            )
            return try rows.map { row in SeriesEntry(book: try Book(row: row), position: row["seriesPosition"]) }
        }
    }

    public func series(containing bookId: Book.ID) async throws -> (series: Series, position: Double?)? {
        try await database.writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.*, sb.position AS seriesPosition
                    FROM series s JOIN series_book sb ON sb.seriesId = s.id
                    WHERE sb.bookId = ?
                    """,
                arguments: [bookId]
            )
            guard let row else { return nil }
            let position: Double? = row["seriesPosition"]
            return (series: try Series(row: row), position: position)
        }
    }

    public func createSeries(named name: String) async throws -> Series {
        let name = try validatedName(name)
        return try await mappingDuplicateName {
            try await database.writer.write { db in
                let series = Series(name: name)
                try series.insert(db)
                return series
            }
        }
    }

    public func findOrCreateSeries(named name: String) async throws -> Series {
        let name = try validatedName(name)
        return try await database.writer.write { db in
            // `name` is a NOCASE column, so this matches the unique index's idea of a duplicate.
            if let existing = try Series.filter(Column("name") == name).fetchOne(db) { return existing }
            let series = Series(name: name)
            try series.insert(db)
            return series
        }
    }

    public func renameSeries(id: Series.ID, to name: String) async throws {
        let name = try validatedName(name)
        try await mappingDuplicateName {
            try await database.writer.write { db in
                try db.execute(sql: "UPDATE series SET name = ? WHERE id = ?", arguments: [name, id])
            }
        }
    }

    public func deleteSeries(id: Series.ID) async throws {
        try await database.writer.write { db in _ = try Series.deleteOne(db, key: id) }
    }

    public func setSeries(_ seriesId: Series.ID?, position: Double?, forBook bookId: Book.ID) async throws {
        try await database.writer.write { db in
            guard let seriesId else {
                try db.execute(sql: "DELETE FROM series_book WHERE bookId = ?", arguments: [bookId])
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO series_book (seriesId, bookId, position) VALUES (?, ?, ?)
                    ON CONFLICT (bookId) DO UPDATE SET seriesId = excluded.seriesId, position = excluded.position
                    """,
                arguments: [seriesId, bookId, position]
            )
        }
    }
}

// MARK: - Bookmarks and reading positions

public struct DatabaseBookmarkRepository: BookmarkRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func observeBookmarks(forBook bookId: Book.ID) -> AsyncThrowingStream<[Bookmark], any Error> {
        database.observe { db in
            try Bookmark.fetchAll(
                db,
                sql: "SELECT * FROM bookmark WHERE bookId = ? ORDER BY progression, createdAt",
                arguments: [bookId]
            )
        }
    }

    public func addBookmark(_ bookmark: Bookmark) async throws {
        try await database.writer.write { db in try bookmark.insert(db) }
    }

    public func deleteBookmark(id: Bookmark.ID) async throws {
        try await database.writer.write { db in _ = try Bookmark.deleteOne(db, key: id) }
    }
}

public struct DatabaseReadingPositionRepository: ReadingPositionRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func position(forBook bookId: Book.ID) async throws -> ReadingPosition? {
        try await database.writer.read { db in try ReadingPosition.fetchOne(db, key: bookId) }
    }

    public func savePosition(_ position: ReadingPosition, progression: Double) async throws {
        let progression = min(max(progression, 0), 1)
        try await database.writer.write { db in
            try position.save(db)
            try db.execute(
                sql: "UPDATE book SET progression = ? WHERE id = ?",
                arguments: [progression, position.bookId]
            )
        }
    }
}

// MARK: - Library sources

public struct DatabaseLibrarySourceRepository: LibrarySourceRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func observeSources() -> AsyncThrowingStream<[LibrarySource], any Error> {
        database.observe { db in
            let sources = try LibrarySource.fetchAll(db)
            let order = SourceKind.allCases
            return sources.sorted { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
        }
    }

    public func source(id: LibrarySource.ID) async throws -> LibrarySource? {
        try await database.writer.read { db in try LibrarySource.fetchOne(db, key: id) }
    }

    public func source(kind: SourceKind) async throws -> LibrarySource? {
        try await database.writer.read { db in
            try LibrarySource.fetchOne(
                db,
                sql: "SELECT * FROM library_source WHERE kind = ?",
                arguments: [kind.rawValue]
            )
        }
    }

    public func addSource(_ source: LibrarySource) async throws {
        guard source.kind != .local else { throw RepositoryError.localIsNotASource }
        do {
            try await database.writer.write { db in try source.insert(db) }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw RepositoryError.sourceAlreadyLinked
        }
    }

    public func changeRoot(
        id: LibrarySource.ID,
        rootId: String?,
        rootBookmark: Data?,
        rootDisplayPath: String
    ) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE library_source
                    SET rootId = ?, rootBookmark = ?, rootDisplayPath = ?, syncCursor = NULL
                    WHERE id = ?
                    """,
                arguments: [rootId, rootBookmark, rootDisplayPath, id]
            )
        }
    }

    public func saveRootBookmark(id: LibrarySource.ID, bookmark: Data?) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE library_source SET rootBookmark = ? WHERE id = ?", arguments: [bookmark, id])
        }
    }

    public func recordSyncSuccess(id: LibrarySource.ID, cursor: String?, at date: Date) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE library_source
                    SET syncCursor = ?, status = 'ok', lastSyncedAt = ?, lastSyncError = NULL
                    WHERE id = ?
                    """,
                arguments: [cursor, date, id]
            )
        }
    }

    public func unlinkSource(id: LibrarySource.ID) async throws -> SourceUnlinkChanges {
        try await database.writer.write { db in
            let books = try Book.fetchAll(db, sql: "SELECT * FROM book WHERE sourceId = ?", arguments: [id])
            var changes = SourceUnlinkChanges()
            for book in books {
                if book.localFilePath == nil {
                    // Cascades remove its bookmarks, position, and memberships; a trigger removes its search row.
                    _ = try Book.deleteOne(db, key: book.id)
                    changes.removed.append(book)
                } else {
                    changes.detached.append(book)
                }
            }
            try db.execute(sql: "UPDATE book SET sourceId = NULL WHERE sourceId = ?", arguments: [id])
            _ = try LibrarySource.deleteOne(db, key: id)
            return changes
        }
    }

    public func recordSyncFailure(id: LibrarySource.ID, status: SourceStatus, message: String?) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE library_source SET status = ?, lastSyncError = ? WHERE id = ?",
                arguments: [status.rawValue, message, id]
            )
        }
    }
}

// MARK: - Helpers

extension AppDatabase {
    /// A stream of `fetch` results: the current value first, then a new one after every change to the tables it read.
    func observe<Value: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, any Error> {
        let reader = writer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in ValueObservation.tracking(fetch).values(in: reader) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Trims `name` and rejects it if nothing is left.
func validatedName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RepositoryError.emptyName }
    return trimmed
}

/// Turns a UNIQUE constraint failure into `RepositoryError.duplicateName`.
func mappingDuplicateName<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
        throw RepositoryError.duplicateName
    }
}
