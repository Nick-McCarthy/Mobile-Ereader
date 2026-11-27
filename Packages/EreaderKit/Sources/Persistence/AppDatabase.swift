import Foundation
import GRDB

/// The app's SQLite database (action plan P1.1). Schema: docs/DATA_MODEL.md.
///
/// Feature code should go through the repositories (P1.2) rather than using `writer` directly.
public struct AppDatabase: Sendable {
    /// Read and write access to the database.
    public let writer: any DatabaseWriter

    /// Wraps `writer` and applies every pending migration.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// All schema migrations, in order. Append new ones; never edit a migration that has shipped.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Schema.registerMigrations(in: &migrator)
        return migrator
    }

    /// Connection settings shared by every database the app opens.
    public static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "EreaderDatabase"
        return configuration
    }

    /// An empty in-memory database, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()))
    }

    /// Opens (creating if needed) the database file at `url`, with Data Protection applied.
    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileProtection.createDirectory(at: url.deletingLastPathComponent())
        let pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: makeConfiguration())
        try FileProtection.apply(to: url)
        return try AppDatabase(pool)
    }

    /// `Application Support/Database/library.sqlite`. See docs/ARCHITECTURE.md#file-storage-on-device.
    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Database", isDirectory: true)
            .appendingPathComponent("library.sqlite")
    }
}

/// Applies the app's Data Protection class. A no-op on macOS, where `swift test` runs.
enum FileProtection {
    // Computed: a stored `[FileAttributeKey: Any]` isn't Sendable, so it can't be a static `let` in Swift 6.
    static var directoryAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
            return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
            return nil
        #endif
    }

    /// Creates `url` (and parents). Files created inside it later inherit its protection class.
    static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
    }

    /// Sets the protection class on an existing file.
    static func apply(to url: URL) throws {
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path(percentEncoded: false)
            )
        #endif
    }
}
