import BookStorage
import Core
import LibraryServices
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// Library tab: the grid or list of books (P3.1), Files import (P1.5), and pull to refresh (P2.8). Sort, search,
/// the collections view, and tapping a book arrive with the rest of Phase 3 (docs/UI_SPEC.md#library).
struct LibraryView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(BookImportController.self) private var importController
    @Environment(SyncCoordinator.self) private var sync
    @AppStorage("authorDisplayFormat") private var authorFormat = AuthorDisplayFormat.asStored
    @AppStorage(LibraryViewMode.storageKey) private var viewMode = LibraryViewMode.grid
    @State private var books: [Book] = []
    /// Running downloads (0…1), from `DownloadManager`.
    @State private var downloadProgress: [Book.ID: Double] = [:]
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView(
                        "No Books Yet",
                        systemImage: "books.vertical",
                        description: Text("Import an EPUB or connect iCloud Drive, Dropbox, or OneDrive in Settings.")
                            .foregroundStyle(.secondaryText)
                    )
                } else {
                    switch viewMode {
                    case .grid:
                        LibraryGridView(
                            books: books,
                            downloadProgress: downloadProgress,
                            authorFormat: authorFormat,
                            files: environment?.files
                        )
                        .refreshable { await sync.sync() }
                    case .list:
                        LibraryListView(
                            books: books,
                            downloadProgress: downloadProgress,
                            authorFormat: authorFormat,
                            files: environment?.files
                        )
                        .refreshable { await sync.sync() }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { SyncBanner() }
            // On the content rather than the stack, so it doesn't share a view with the error alert.
            .alert(
                "Already in Your Library",
                isPresented: Binding(get: { !importController.duplicates.isEmpty }, set: { _ in }),
                presenting: importController.duplicates.first
            ) { _ in
                Button("Replace") { importController.resolveFirstDuplicate(.replace) }
                Button("Keep Both") { importController.resolveFirstDuplicate(.keepBoth) }
                Button("Skip", role: .cancel) { importController.resolveFirstDuplicate(.skip) }
            } message: { duplicate in
                Text("“\(duplicate.title)” is already in your library. Replace it, or keep both?")
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    LibraryViewModeMenu(mode: $viewMode)
                }
                ToolbarItem(placement: .primaryAction) {
                    if importController.isImporting {
                        ProgressView().accessibilityLabel("Importing Books")
                    } else {
                        Button("Import Books", systemImage: "plus") { showingImporter = true }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.epub],
                allowsMultipleSelection: true,
                onCompletion: { result in importPicked(result) }
            )
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importController.errorMessage != nil },
                    set: { if !$0 { importController.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importController.errorMessage ?? "")
            }
        }
        .task {
            guard let environment else { return }
            do {
                for try await latest in environment.repositories.books.observeLibrary(LibraryQuery()) {
                    books = latest
                }
            } catch {
                books = []
            }
        }
        .task {
            guard let environment else { return }
            for await latest in environment.downloads.observeProgress() {
                downloadProgress = latest
            }
        }
    }
}

extension LibraryView {
    /// The picker's URLs are security-scoped; the importer opens and closes access around its copy.
    fileprivate func importPicked(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        Task { await importController.importBooks(urls) }
    }
}
