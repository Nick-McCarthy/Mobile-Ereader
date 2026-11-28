import BookStorage
import Foundation
import LibraryServices
import Persistence
import SwiftUI

/// Everything the features need, built once at launch. See docs/ARCHITECTURE.md#runtime-architecture.
struct AppEnvironment: Sendable {
    let repositories: DatabaseRepositories
    let files: BookFileStore
    let importer: LocalBookImporter

    init(database: AppDatabase, files: BookFileStore) {
        self.repositories = DatabaseRepositories(database: database)
        self.files = files
        self.importer = LocalBookImporter(books: repositories.books, files: files)
    }

    /// The on-device database and folders. UI tests (`-UITestMode`) get an empty in-memory library instead,
    /// so runs don't depend on each other.
    static func live(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> AppEnvironment {
        if arguments.contains("-UITestMode") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("UITest-\(UUID().uuidString)", isDirectory: true)
            let files = BookFileStore(
                applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
                caches: root.appendingPathComponent("Caches", isDirectory: true)
            )
            return AppEnvironment(database: try AppDatabase.inMemory(), files: files)
        }
        return AppEnvironment(database: try AppDatabase.onDisk(at: AppDatabase.defaultURL()), files: try .standard())
    }
}

extension EnvironmentValues {
    @Entry var appEnvironment: AppEnvironment? = nil
}
