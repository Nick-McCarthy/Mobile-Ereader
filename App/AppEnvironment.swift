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
    /// Removes Keychain tokens left by an earlier install. Nil in UI tests, which never touch the Keychain.
    let tokenCleanup: OrphanedTokenCleanup?

    init(database: AppDatabase, files: BookFileStore, usesKeychain: Bool = true) {
        self.repositories = DatabaseRepositories(database: database)
        self.files = files
        self.importer = LocalBookImporter(books: repositories.books, series: repositories.series, files: files)
        let sources = repositories.sources
        let stores = usesKeychain ? OrphanedTokenCleanup.keychainStores() : nil
        self.tokenCleanup = stores.map { OrphanedTokenCleanup(sources: sources, stores: $0) }
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
            return AppEnvironment(database: try AppDatabase.inMemory(), files: files, usesKeychain: false)
        }
        return AppEnvironment(database: try AppDatabase.onDisk(at: AppDatabase.defaultURL()), files: try .standard())
    }
}

extension EnvironmentValues {
    @Entry var appEnvironment: AppEnvironment? = nil
}
