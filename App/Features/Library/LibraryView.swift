import BookStorage
import Core
import LibraryServices
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// Library tab: the grid or list of books (P3.1), sorted (P3.2) and searched (P3.3), Files import (P1.5), and
/// pull to refresh (P2.8). The collections view and tapping a book arrive with the rest of Phase 3
/// (docs/UI_SPEC.md#library).
struct LibraryView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(BookImportController.self) private var importController
    @Environment(SyncCoordinator.self) private var sync
    @AppStorage("authorDisplayFormat") private var authorFormat = AuthorDisplayFormat.asStored
    @AppStorage(LibraryViewMode.storageKey) private var viewMode = LibraryViewMode.grid
    @AppStorage(LibrarySortMenu.sortKey) private var sort = LibrarySortOrder.recentlyViewed
    @AppStorage(LibrarySortMenu.reversedKey) private var sortReversed = false
    @State private var books: [Book] = []
    /// Running downloads (0…1), from `DownloadManager`.
    @State private var downloadProgress: [Book.ID: Double] = [:]
    @State private var showingImporter = false
    /// What's typed in the search field, and the same text once typing pauses, which is what the query uses.
    @State private var searchText = ""
    @State private var searchQuery = ""

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty, !searchQuery.isEmpty {
                    // Not `ContentUnavailableView.search`: its description uses the system secondary colour,
                    // which the accessibility audit flags for contrast.
                    ScrollableUnavailableView {
                        ContentUnavailableView(
                            "No Results",
                            systemImage: "magnifyingglass",
                            description: Text("No books match “\(searchQuery)”. Check the spelling or try other words.")
                                .foregroundStyle(.secondaryText)
                        )
                    }
                } else if books.isEmpty {
                    ScrollableUnavailableView {
                        ContentUnavailableView(
                            "No Books Yet",
                            systemImage: "books.vertical",
                            description: Text(
                                "Import an EPUB or connect iCloud Drive, Dropbox, or OneDrive in Settings."
                            )
                            .foregroundStyle(.secondaryText)
                        )
                    }
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
            // The default "Search" prompt: a longer one is clipped at large Dynamic Type sizes.
            .searchable(text: $searchText)
            .task(id: searchText) { await debounceSearch() }
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
                ToolbarItemGroup(placement: .topBarLeading) {
                    LibraryViewModeMenu(mode: $viewMode)
                    LibrarySortMenu(sort: $sort, reversed: $sortReversed)
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
        // Restarts the observation whenever the sort changes.
        .task(id: query) {
            guard let environment else { return }
            do {
                for try await latest in environment.repositories.books.observeLibrary(query) {
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
    fileprivate var query: LibraryQuery {
        LibraryQuery(sort: sort, reversed: sortReversed, searchText: searchQuery)
    }

    /// Passes the typed text to the query once typing pauses for 150 ms; clearing the field applies at once.
    /// Each keystroke restarts this task, which cancels the previous wait.
    fileprivate func debounceSearch() async {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
        }
        searchQuery = text
    }

    /// The picker's URLs are security-scoped; the importer opens and closes access around its copy.
    fileprivate func importPicked(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        Task { await importController.importBooks(urls) }
    }
}

/// Shows an empty state centred as it is, or in a scroll view when larger Dynamic Type makes it taller than the
/// space it has (the search bar leaves less room), so the text is never clipped. `ViewThatFits` rather than a
/// `GeometryReader`-sized scroll view, whose height feeds back through the collapsing search bar.
private struct ScrollableUnavailableView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }
}
