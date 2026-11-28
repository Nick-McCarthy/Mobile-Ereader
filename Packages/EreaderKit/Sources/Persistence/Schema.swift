import GRDB

/// Schema migrations. Spec: docs/DATA_MODEL.md. Append new migrations at the end; never edit a shipped one.
enum Schema {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1: library schema", migrate: createV1)
    }

    // MARK: - v1

    private static func createV1(_ db: Database) throws {
        try createLibrarySource(db)
        try createBook(db)
        try createReadingData(db)
        try createCollectionsAndSeries(db)
        try createSearchIndex(db)
    }

    private static func createLibrarySource(_ db: Database) throws {
        try db.create(table: "library_source") { t in
            t.primaryKey("id", .text)
            t.column("kind", .text).notNull().unique()
                .check(sql: "kind IN ('iCloud', 'dropbox', 'oneDrive')")
            t.column("accountLabel", .text)
            t.column("rootId", .text)
            t.column("rootBookmark", .blob)
            t.column("rootDisplayPath", .text).notNull().defaults(to: "")
            t.column("syncCursor", .text)
            t.column("status", .text).notNull().defaults(to: "ok")
                .check(sql: "status IN ('ok', 'needsRelink', 'error')")
            t.column("lastSyncedAt", .datetime)
            t.column("lastSyncError", .text)
        }
    }

    private static func createBook(_ db: Database) throws {
        try db.create(table: "book") { t in
            t.primaryKey("id", .text)

            // Where the book comes from. sourceId is null for local imports and for detached books.
            t.column("sourceKind", .text).notNull()
                .check(sql: "sourceKind IN ('local', 'iCloud', 'dropbox', 'oneDrive')")
            t.column("sourceId", .text).references("library_source", onDelete: .setNull)
            t.column("remoteId", .text)
            t.column("remotePath", .text)
            t.column("remoteVersion", .text)
            t.column("remoteModifiedAt", .datetime)
            t.column("fileSize", .integer)
            t.uniqueKey(["sourceId", "remoteId"])

            // Metadata. Placeholders ("Unknown Title"/"Unknown Author") are flagged so they sort last.
            t.column("title", .text).notNull()
            t.column("titleSort", .text).notNull()
            t.column("titleIsPlaceholder", .boolean).notNull().defaults(to: false)
            t.column("authorRaw", .text).notNull()
            t.column("authorIsPlaceholder", .boolean).notNull().defaults(to: false)
            t.column("authorFileAs", .text)
            t.column("authorStoredFormat", .text).notNull().defaults(to: "unknown")
                .check(sql: "authorStoredFormat IN ('firstLast', 'lastFirst', 'unknown')")
            t.column("authorGiven", .text)
            t.column("authorFamily", .text)
            t.column("publicationDate", .text)
            t.column("publicationDateSort", .integer)
            t.column("language", .text)
            t.column("publisher", .text)
            t.column("description", .text)
            t.column("identifier", .text)
            t.column("coverPath", .text)

            // Local file and state.
            t.column("localFilePath", .text)
            t.column("downloadState", .text).notNull().defaults(to: "notDownloaded")
                .check(sql: "downloadState IN ('notDownloaded', 'downloading', 'downloaded', 'failed')")
            t.column("isUserEdited", .boolean).notNull().defaults(to: false)
            t.column("userEditedFields", .text).notNull().defaults(to: "[]")
                .check(sql: "json_valid(userEditedFields)")
            t.column("isMissingFromSource", .boolean).notNull().defaults(to: false)
            t.column("dateAdded", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            t.column("lastOpenedAt", .datetime)
            t.column("progression", .double).notNull().defaults(to: 0)
                .check(sql: "progression BETWEEN 0 AND 1")
        }
        // Re-attaching detached books on re-link matches on (sourceKind, remoteId).
        try db.create(index: "book_on_sourceKind_remoteId", on: "book", columns: ["sourceKind", "remoteId"])
        try db.create(index: "book_on_lastOpenedAt", on: "book", columns: ["lastOpenedAt"])
        try db.create(index: "book_on_titleSort", on: "book", columns: ["titleSort"])
        try db.create(
            index: "book_on_authorFamily_authorGiven",
            on: "book",
            columns: ["authorFamily", "authorGiven"]
        )
        try db.create(index: "book_on_publicationDateSort", on: "book", columns: ["publicationDateSort"])
    }

    private static func createReadingData(_ db: Database) throws {
        try db.create(table: "reading_position") { t in
            t.primaryKey("bookId", .text).references("book", onDelete: .cascade)
            t.column("locatorJSON", .text).notNull()
            t.column("updatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        }

        try db.create(table: "bookmark") { t in
            t.primaryKey("id", .text)
            t.column("bookId", .text).notNull().references("book", onDelete: .cascade)
            t.column("locatorJSON", .text).notNull()
            t.column("chapterTitle", .text)
            t.column("progression", .double).notNull().check(sql: "progression BETWEEN 0 AND 1")
            t.column("textSnippet", .text).check(sql: "length(textSnippet) <= 160")
            t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        }
        try db.create(index: "bookmark_on_bookId_progression", on: "bookmark", columns: ["bookId", "progression"])
    }

    private static func createCollectionsAndSeries(_ db: Database) throws {
        try db.create(table: "collection") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull().unique().collate(.nocase)
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        }

        try db.create(table: "collection_book") { t in
            t.column("collectionId", .text).notNull().references("collection", onDelete: .cascade)
            t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
            t.column("addedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            t.primaryKey(["collectionId", "bookId"])
        }

        try db.create(table: "series") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull().unique().collate(.nocase)
            t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        }

        try db.create(table: "series_book") { t in
            t.column("seriesId", .text).notNull().indexed().references("series", onDelete: .cascade)
            // A book belongs to at most one series.
            t.primaryKey("bookId", .text).references("book", onDelete: .cascade)
            t.column("position", .double)
        }
    }

    // MARK: - Full-text search

    /// `book_fts` holds one row per book: title, authors, series name, and collection names.
    /// FTS5 tokenises, so "ursula le guin" matches "Le Guin, Ursula K." without storing both name orders.
    /// Triggers keep it in sync with `book`, `series`, `series_book`, `collection`, and `collection_book`.
    private static func createSearchIndex(_ db: Database) throws {
        try db.execute(
            sql: """
                CREATE VIRTUAL TABLE book_fts USING fts5(
                    bookId UNINDEXED, title, author, series, collections,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """
        )

        let seriesMembers = "SELECT bookId FROM series_book WHERE seriesId = NEW.id"
        let collectionMembers = "SELECT bookId FROM collection_book WHERE collectionId = NEW.id"

        try trigger(db, "book_ai", "AFTER INSERT ON book", reindex("NEW.id"))
        try trigger(db, "book_au", "AFTER UPDATE OF title, authorRaw, authorFileAs ON book", reindex("NEW.id"))
        try trigger(db, "book_ad", "AFTER DELETE ON book", "DELETE FROM book_fts WHERE bookId = OLD.id;")
        try trigger(db, "series_book_ai", "AFTER INSERT ON series_book", reindex("NEW.bookId"))
        try trigger(db, "series_book_au", "AFTER UPDATE ON series_book", reindex("OLD.bookId, NEW.bookId"))
        try trigger(db, "series_book_ad", "AFTER DELETE ON series_book", reindex("OLD.bookId"))
        try trigger(db, "collection_book_ai", "AFTER INSERT ON collection_book", reindex("NEW.bookId"))
        try trigger(db, "collection_book_au", "AFTER UPDATE ON collection_book", reindex("OLD.bookId, NEW.bookId"))
        try trigger(db, "collection_book_ad", "AFTER DELETE ON collection_book", reindex("OLD.bookId"))
        try trigger(db, "series_au", "AFTER UPDATE OF name ON series", reindex(seriesMembers))
        try trigger(db, "collection_au", "AFTER UPDATE OF name ON collection", reindex(collectionMembers))
    }

    private static func trigger(_ db: Database, _ name: String, _ event: String, _ body: String) throws {
        try db.execute(sql: "CREATE TRIGGER \(name) \(event) BEGIN \(body) END")
    }

    /// SQL that rebuilds the search rows of the books whose ids are listed by `bookIds`
    /// (a comma-separated list of expressions, or a subquery).
    private static func reindex(_ bookIds: String) -> String {
        """
        DELETE FROM book_fts WHERE bookId IN (\(bookIds));
        INSERT INTO book_fts (bookId, title, author, series, collections)
        SELECT
            b.id,
            b.title,
            b.authorRaw || ' ' || ifnull(b.authorFileAs, ''),
            ifnull(
                (SELECT group_concat(s.name, ' ') FROM series_book sb JOIN series s ON s.id = sb.seriesId
                 WHERE sb.bookId = b.id), ''),
            ifnull(
                (SELECT group_concat(c.name, ' ') FROM collection_book cb JOIN collection c ON c.id = cb.collectionId
                 WHERE cb.bookId = b.id), '')
        FROM book b
        WHERE b.id IN (\(bookIds));
        """
    }
}
