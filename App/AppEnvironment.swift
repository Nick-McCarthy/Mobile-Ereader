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
    /// UI tests only (`-UITestSeedBooks`): books in each download state, and two collections, so audits see a
    /// non-empty library.
    let uiTestSeedBooks: [Book]
    /// Removes detached books whose file is gone (docs/REMOTE_SOURCES.md#unlinking--detached-books).
    let detachedBookCheck: DetachedBookCheck
    let bookSources: BookSources
    let syncEngine: SyncEngine
    let downloads: DownloadManager
    let unlinker: SourceUnlinker
    /// UI tests only (`-UITestLinkedFolder`): an empty folder to link as the iCloud source at launch.
    let uiTestLinkedFolder: URL?

    init(
        database: AppDatabase,
        files: BookFileStore,
        usesKeychain: Bool = true,
        uiTestSeedBooks: [Book] = [],
        uiTestLinkedFolder: URL? = nil
    ) {
        self.repositories = DatabaseRepositories(database: database)
        self.files = files
        self.importer = LocalBookImporter(books: repositories.books, series: repositories.series, files: files)
        let sources = repositories.sources
        let stores = usesKeychain ? OrphanedTokenCleanup.keychainStores() : nil
        self.tokenCleanup = stores.map { OrphanedTokenCleanup(sources: sources, stores: $0) }
        self.uiTestSeedBooks = uiTestSeedBooks
        self.detachedBookCheck = DetachedBookCheck(books: repositories.books, files: files)
        self.bookSources = BookSources(sources: sources)
        self.syncEngine = SyncEngine(
            books: repositories.books,
            series: repositories.series,
            sources: sources,
            files: files
        )
        let downloads = DownloadManager(books: repositories.books, files: files)
        self.downloads = downloads
        self.unlinker = SourceUnlinker(books: repositories.books, sources: sources, files: files, downloads: downloads)
        self.uiTestLinkedFolder = uiTestLinkedFolder
    }

    /// One-off work at launch: removes Keychain tokens left by an earlier install (finding F-A1), removes
    /// detached books whose file is gone, and seeds the UI-test books (after that check, which would remove them).
    func prepareAtLaunch() async {
        if let uiTestLinkedFolder { _ = try? await bookSources.linkFolder(at: uiTestLinkedFolder) }
        _ = try? await tokenCleanup?.run()
        _ = try? await detachedBookCheck.run()
        for book in uiTestSeedBooks { try? await repositories.books.save(book) }
        if !uiTestSeedBooks.isEmpty { await seedUITestCollections() }
    }

    /// "Le Guin" holds both Le Guin books and "Favourites" one of them; the other two books are in none.
    private func seedUITestCollections() async {
        let collections = repositories.collections
        guard let leGuin = try? await collections.createCollection(named: "Le Guin"),
            let favourites = try? await collections.createCollection(named: "Favourites")
        else { return }
        try? await collections.addBook("uitest-book", toCollection: leGuin.id)
        try? await collections.addBook("uitest-failed", toCollection: leGuin.id)
        try? await collections.addBook("uitest-book", toCollection: favourites.id)
    }

    /// A downloaded book part-read, a placeholder book not downloaded, one whose download failed, and one missing
    /// from its folder. Remote books have no source, so they count as detached; that doesn't change how they show.
    private static var uiTestBooks: [Book] {
        var tombs = Book(
            id: "uitest-book",
            sourceKind: .local,
            title: "The Tombs of Atuan",
            authorRaw: "Ursula K. Le Guin"
        )
        tombs.downloadState = .downloaded
        tombs.progression = 0.42
        tombs.publicationDate = "1971"
        tombs.publicationDateSort = 1971_0000
        var placeholder = Book(id: "uitest-placeholder", sourceKind: .iCloud, title: nil, authorRaw: nil)
        placeholder.downloadState = .notDownloaded
        var failed = Book(
            id: "uitest-failed",
            sourceKind: .iCloud,
            title: "The Left Hand of Darkness",
            authorRaw: "Le Guin, Ursula K."
        )
        failed.downloadState = .failed
        var missing = Book(id: "uitest-missing", sourceKind: .iCloud, title: "Anathem", authorRaw: "Neal Stephenson")
        missing.downloadState = .notDownloaded
        missing.isMissingFromSource = true
        return [tombs, placeholder, failed, missing]
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
            let seed = arguments.contains("-UITestSeedBooks") ? uiTestBooks : []
            // Each run starts in the default view mode and sort, whatever an earlier test chose.
            let keys = [
                LibraryViewMode.storageKey,
                LibrarySortMenu.sortKey,
                LibrarySortMenu.reversedKey,
                StoredIDSet.libraryCollapsedKey,
            ]
            for key in keys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            var folder: URL?
            if arguments.contains("-UITestLinkedFolder") {
                let books = root.appendingPathComponent("UITest Books", isDirectory: true)
                try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
                folder = books
            }
            return AppEnvironment(
                database: try AppDatabase.inMemory(),
                files: files,
                usesKeychain: false,
                uiTestSeedBooks: seed,
                uiTestLinkedFolder: folder
            )
        }
        return AppEnvironment(database: try AppDatabase.onDisk(at: AppDatabase.defaultURL()), files: try .standard())
    }
}

extension EnvironmentValues {
    @Entry var appEnvironment: AppEnvironment? = nil
}
