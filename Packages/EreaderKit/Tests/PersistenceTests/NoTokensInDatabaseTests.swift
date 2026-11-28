import GRDB
import Persistence
import Testing

@Suite("No credentials in the database")
struct NoTokensInDatabaseTests {
    @Test("No table has a column that could hold a token, password, or secret")
    func noCredentialColumns() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.writer.read { db in
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            )
            return try tables.flatMap { table in try db.columns(in: table).map { "\(table).\($0.name)" } }
        }
        #expect(!columns.isEmpty)
        let suspicious = columns.filter { column in
            ["token", "password", "secret", "credential"].contains { column.lowercased().contains($0) }
        }
        #expect(suspicious.isEmpty, "credential-like columns: \(suspicious)")
    }
}
