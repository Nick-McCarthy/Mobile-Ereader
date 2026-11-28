import Foundation
import GRDB
import Persistence
import Testing

@Suite("AppDatabase schema v1")
struct AppDatabaseTests {
    let database: AppDatabase

    init() throws {
        database = try AppDatabase.inMemory()
    }

    // MARK: Migrations

    @Test("All migrations run and every table exists")
    func migrationsCreateSchema() throws {
        let (completed, missingTables) = try database.writer.read { db in
            let completed = try AppDatabase.migrator.hasCompletedMigrations(db)
            let missing = try expectedTables.filter { try !db.tableExists($0) }
            return (completed, missing)
        }
        #expect(completed)
        #expect(missingTables.isEmpty, "missing tables: \(missingTables)")
    }

    @Test("Opening an on-disk database twice keeps the schema")
    func onDiskDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Database/library.sqlite")

        let first = try AppDatabase.onDisk(at: url)
        try first.writer.write { db in try insertBook(db, id: "b1", title: "Kept", author: "Someone") }

        let second = try AppDatabase.onDisk(at: url)
        let count = try second.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM book") }
        #expect(count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    // MARK: Full-text search

    @Test("Search finds books by title, by author in either name order, and ignores diacritics")
    func searchByTitleAndAuthor() throws {
        try database.writer.write { db in
            try insertBook(db, id: "earthsea", title: "The Left Hand of Darkness", author: "Le Guin, Ursula K.")
            try insertBook(
                db, id: "solitude", title: "One Hundred Years of Solitude", author: "Gabriel García Márquez")

            #expect(try search(db, "darkness") == ["earthsea"])
            #expect(try search(db, "dark") == ["earthsea"], "prefix match")
            #expect(try search(db, "le guin") == ["earthsea"])
            #expect(try search(db, "ursula guin") == ["earthsea"], "first-last order")
            #expect(try search(db, "garcia marquez") == ["solitude"], "diacritics ignored")
            #expect(try search(db, "tolkien").isEmpty)
        }
    }

    @Test("Search follows title edits and deletions")
    func searchFollowsEdits() throws {
        try database.writer.write { db in
            try insertBook(db, id: "b1", title: "Original Title", author: "Author")
            try db.execute(sql: "UPDATE book SET title = 'Renamed' WHERE id = 'b1'")
            #expect(try search(db, "original").isEmpty)
            #expect(try search(db, "renamed") == ["b1"])

            try db.execute(sql: "DELETE FROM book WHERE id = 'b1'")
            #expect(try search(db, "renamed").isEmpty)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM book_fts") == 0)
        }
    }

    @Test("Search includes series and collection names and follows renames and removals")
    func searchIncludesSeriesAndCollections() throws {
        try database.writer.write { db in
            try insertBook(db, id: "b1", title: "A Wizard of Earthsea", author: "Ursula K. Le Guin")
            try db.execute(sql: "INSERT INTO series (id, name) VALUES ('s1', 'Earthsea Cycle')")
            try db.execute(sql: "INSERT INTO series_book (seriesId, bookId, position) VALUES ('s1', 'b1', 1)")
            try db.execute(sql: "INSERT INTO collection (id, name) VALUES ('c1', 'Favourites')")
            try db.execute(sql: "INSERT INTO collection_book (collectionId, bookId) VALUES ('c1', 'b1')")

            #expect(try search(db, "cycle") == ["b1"])
            #expect(try search(db, "favourites") == ["b1"])

            try db.execute(sql: "UPDATE collection SET name = 'Comfort Reads' WHERE id = 'c1'")
            #expect(try search(db, "favourites").isEmpty)
            #expect(try search(db, "comfort") == ["b1"])

            try db.execute(sql: "DELETE FROM series WHERE id = 's1'")
            #expect(try search(db, "cycle").isEmpty, "deleting a series cascades to the search index")
            #expect(try search(db, "wizard") == ["b1"], "the book itself stays searchable")
        }
    }

    // MARK: Relationships and constraints

    @Test("Deleting a book removes its bookmarks, position, and memberships")
    func bookDeletionCascades() throws {
        try database.writer.write { db in
            try insertBook(db, id: "b1", title: "Book", author: "Author")
            try db.execute(
                sql: "INSERT INTO bookmark (id, bookId, locatorJSON, progression) VALUES ('m1', 'b1', '{}', 0.5)")
            try db.execute(sql: "INSERT INTO reading_position (bookId, locatorJSON) VALUES ('b1', '{}')")
            try db.execute(sql: "INSERT INTO collection (id, name) VALUES ('c1', 'Shelf')")
            try db.execute(sql: "INSERT INTO collection_book (collectionId, bookId) VALUES ('c1', 'b1')")

            try db.execute(sql: "DELETE FROM book WHERE id = 'b1'")

            for table in ["bookmark", "reading_position", "collection_book"] {
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0, "\(table) not cleaned up")
            }
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM collection") == 1, "collections are kept")
        }
    }

    @Test("Deleting a library source detaches its books instead of deleting them")
    func unlinkDetachesBooks() throws {
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO library_source (id, kind) VALUES ('src', 'dropbox')")
            try insertBook(db, id: "b1", title: "Book", author: "Author", source: ("dropbox", "src", "id:abc"))

            try db.execute(sql: "DELETE FROM library_source WHERE id = 'src'")

            let row = try #require(try Row.fetchOne(db, sql: "SELECT sourceId, sourceKind, remoteId FROM book"))
            #expect(row["sourceId"] as String? == nil)
            #expect(row["sourceKind"] as String == "dropbox")
            #expect(row["remoteId"] as String == "id:abc")
        }
    }

    @Test("Invalid values and duplicates are rejected")
    func constraints() throws {
        try database.writer.write { db in
            #expect(throws: DatabaseError.self) {
                try insertBook(db, id: "bad", title: "Book", author: "Author", source: ("googleDrive", nil, nil))
            }

            try db.execute(sql: "INSERT INTO collection (id, name) VALUES ('c1', 'Favourites')")
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO collection (id, name) VALUES ('c2', 'FAVOURITES')")
            }

            try db.execute(sql: "INSERT INTO library_source (id, kind) VALUES ('src', 'oneDrive')")
            try insertBook(db, id: "b1", title: "One", author: "A", source: ("oneDrive", "src", "item-1"))
            #expect(throws: DatabaseError.self) {
                try insertBook(db, id: "b2", title: "Two", author: "B", source: ("oneDrive", "src", "item-1"))
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO library_source (id, kind) VALUES ('src2', 'oneDrive')")
            }
        }
    }
}

// MARK: - Helpers

private let expectedTables = [
    "library_source",
    "book",
    "book_fts",
    "reading_position",
    "bookmark",
    "collection",
    "collection_book",
    "series",
    "series_book",
]

/// Inserts a book with only the required columns. `source` is (sourceKind, sourceId, remoteId).
private func insertBook(
    _ db: Database,
    id: String,
    title: String,
    author: String,
    source: (kind: String, id: String?, remoteId: String?) = ("local", nil, nil)
) throws {
    try db.execute(
        sql: """
            INSERT INTO book (id, sourceKind, sourceId, remoteId, title, titleSort, authorRaw)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
        arguments: [id, source.kind, source.id, source.remoteId, title, title.lowercased(), author]
    )
}

/// Book ids matching `text`, using the same prefix-matching pattern the library search will use.
private func search(_ db: Database, _ text: String) throws -> [String] {
    guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
    return try String.fetchAll(
        db,
        sql: "SELECT bookId FROM book_fts WHERE book_fts MATCH ? ORDER BY bookId",
        arguments: [pattern]
    )
}
