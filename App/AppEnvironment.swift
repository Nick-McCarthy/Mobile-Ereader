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
    /// UI tests only (`-UITestSeedBook`): a book to show, so audits see a non-empty library.
    let uiTestSeedBook: Book?
    /// Removes detached books whose file is gone (docs/REMOTE_SOURCES.md#unlinking--detached-books).
    let detachedBookCheck: DetachedBookCheck

    init(database: AppDatabase, files: BookFileStore, usesKeychain: Bool = true, uiTestSeedBook: Book? = nil) {
        self.repositories = DatabaseRepositories(database: database)
        self.files = files
        self.importer = LocalBookImporter(books: repositories.books, series: repositories.series, files: files)
        let sources = repositories.sources
        let stores = usesKeychain ? OrphanedTokenCleanup.keychainStores() : nil
        self.tokenCleanup = stores.map { OrphanedTokenCleanup(sources: sources, stores: $0) }
        self.uiTestSeedBook = uiTestSeedBook
        self.detachedBookCheck = DetachedBookCheck(books: repositories.books, files: files)
    }

    /// One-off work at launch: seeds the UI-test book, removes Keychain tokens left by an earlier install
    /// (finding F-A1), and removes detached books whose file is gone.
    func prepareAtLaunch() async {
        if let uiTestSeedBook { try? await repositories.books.save(uiTestSeedBook) }
        _ = try? await tokenCleanup?.run()
        _ = try? await detachedBookCheck.run()
    }

    private static let uiTestBook = Book(
        id: "uitest-book",
        sourceKind: .local,
        title: "The Tombs of Atuan",
        authorRaw: "Ursula K. Le Guin"
    )

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
            let seed = arguments.contains("-UITestSeedBook") ? uiTestBook : nil
            return AppEnvironment(
                database: try AppDatabase.inMemory(),
                files: files,
                usesKeychain: false,
                uiTestSeedBook: seed
            )
        }
        return AppEnvironment(database: try AppDatabase.onDisk(at: AppDatabase.defaultURL()), files: try .standard())
    }
}

extension EnvironmentValues {
    @Entry var appEnvironment: AppEnvironment? = nil
}
