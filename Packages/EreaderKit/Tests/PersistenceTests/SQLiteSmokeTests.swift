import GRDB
import Testing

@Suite("SQLite support")
struct SQLiteSmokeTests {
    @Test("GRDB opens an in-memory database with FTS5 available for library search")
    func fts5IsAvailable() throws {
        let dbQueue = try DatabaseQueue()
        let matches = try dbQueue.write { db -> Int in
            try db.execute(sql: "CREATE VIRTUAL TABLE book_fts USING fts5(title, author)")
            try db.execute(
                sql: "INSERT INTO book_fts(title, author) VALUES (?, ?)",
                arguments: ["The Left Hand of Darkness", "Ursula K. Le Guin"]
            )
            let sql = "SELECT count(*) FROM book_fts WHERE book_fts MATCH ?"
            return try Int.fetchOne(db, sql: sql, arguments: ["darkness"]) ?? 0
        }
        #expect(matches == 1)
    }
}
