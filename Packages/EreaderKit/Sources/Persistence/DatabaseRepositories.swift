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

    public init(database: AppDatabase) {
        books = DatabaseBookRepository(database: database)
        collections = DatabaseCollectionRepository(database: database)
        series = DatabaseSeriesRepository(database: database)
        bookmarks = DatabaseBookmarkRepository(database: database)
        readingPositions = DatabaseReadingPositionRepository(database: database)
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
