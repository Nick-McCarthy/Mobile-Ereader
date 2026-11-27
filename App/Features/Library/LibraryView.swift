import SwiftUI

/// Library tab: grid / list / collections views, sort, and search (action plan Phase 3).
struct LibraryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Books Yet",
                systemImage: "books.vertical",
                description: Text("Import an EPUB or connect iCloud Drive, Dropbox, or OneDrive in Settings.")
            )
            .navigationTitle("Library")
        }
    }
}
