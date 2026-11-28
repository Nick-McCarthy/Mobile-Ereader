import LibraryServices
import Persistence
import SwiftUI

/// What tapping a book does, handed down from `LibraryView` to the grid, list, and collection rows.
struct OpenBookAction {
    let handler: @MainActor (Book) -> Void

    @MainActor
    func callAsFunction(_ book: Book) {
        handler(book)
    }
}

extension EnvironmentValues {
    @Entry var openBook = OpenBookAction { _ in }
}

/// A tap that couldn't open its book, for the library's alert.
struct OpenFailure: Identifiable {
    let id = UUID()
    let title: String
    let reason: BookOpenError

    var alertTitle: LocalizedStringKey {
        switch reason {
        case .offline: "You're Offline"
        case .needsRelink: "Link the Folder Again"
        case .missingFromSource: "Book Not Found"
        case .changedInSource: "Book Changed"
        case .notDownloadable: "Can't Download"
        case .fileMissing: "Book File Missing"
        case .downloadFailed: "Download Failed"
        }
    }

    var message: String {
        switch reason {
        case .offline:
            String(localized: "Connect to the internet to download “\(title)”.")
        case .needsRelink:
            String(localized: "The app lost access to the folder “\(title)” is in. Choose it again in Settings.")
        case .missingFromSource:
            String(localized: "“\(title)” is no longer in the linked folder.")
        case .changedInSource:
            String(localized: "“\(title)” changed since the last sync. Pull down to sync, then try again.")
        case .notDownloadable:
            String(localized: "“\(title)” can't be downloaded: its source isn't linked, or this version can't read it.")
        case .fileMissing:
            String(localized: "The file for “\(title)” is no longer on this iPhone. Import it again to read it.")
        case .downloadFailed:
            String(localized: "“\(title)” couldn't be downloaded. Try again.")
        }
    }
}

/// Stands in for the reader until Phase 5 (docs/READER.md): the book that would open, and a way back.
struct ReaderPlaceholderView: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                book.title,
                systemImage: "book",
                description: Text("The reader arrives in a later version.").foregroundStyle(.secondaryText)
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        // A full-screen cover doesn't always take the tab view's tint.
        .tint(.accessibleAccent)
    }
}
