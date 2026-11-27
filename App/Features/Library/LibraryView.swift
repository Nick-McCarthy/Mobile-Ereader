import BookStorage
import Core
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// Library tab. For now a plain list with Files import (P1.5); the grid, list, and collections views,
/// sort, and search arrive in Phase 3 (docs/UI_SPEC.md).
struct LibraryView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(BookImportController.self) private var importController
    @AppStorage("authorDisplayFormat") private var authorFormat = AuthorDisplayFormat.asStored
    @State private var books: [Book] = []
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView(
                        "No Books Yet",
                        systemImage: "books.vertical",
                        description: Text("Import an EPUB or connect iCloud Drive, Dropbox, or OneDrive in Settings.")
                    )
                } else {
                    List(books) { book in
                        BookRow(book: book, authorFormat: authorFormat, files: environment?.files)
                    }
                }
            }
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
                ToolbarItem(placement: .primaryAction) {
                    if importController.isImporting {
                        ProgressView()
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
    }
}

extension LibraryView {
    /// The picker's URLs are security-scoped; the importer opens and closes access around its copy.
    fileprivate func importPicked(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        Task { await importController.importBooks(urls) }
    }
}

/// One book in the temporary list: cover thumbnail, title, and author in the chosen format.
private struct BookRow: View {
    let book: Book
    let authorFormat: AuthorDisplayFormat
    let files: BookFileStore?

    var body: some View {
        HStack(spacing: 12) {
            cover
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(AuthorNameFormatter.string(for: book.authorName, in: authorFormat))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @State private var loadedCover: UIImage?

    private var coverURL: URL? {
        guard let path = book.coverPath, let files else { return nil }
        return files.url(forCoverPath: path)
    }

    /// Decorative: the row's text already names the book, so VoiceOver skips it.
    private var cover: some View {
        Group {
            if let image = loadedCover ?? coverURL.flatMap(CoverImageCache.shared.cachedImage(at:)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary).overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
        }
        .accessibilityHidden(true)
        .task(id: coverURL) {
            loadedCover = nil
            guard let coverURL else { return }
            loadedCover = await CoverImageCache.shared.image(at: coverURL)
        }
    }
}
