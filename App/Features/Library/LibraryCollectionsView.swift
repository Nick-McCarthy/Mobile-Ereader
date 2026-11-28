import BookStorage
import Core
import Foundation
import Persistence
import SwiftUI

/// The library's collections view: the books (sorted and searched as in the other views) grouped by collection
/// in collapsible sections, then "Not in a Collection". Which sections are collapsed is kept in `@AppStorage`.
/// See docs/UI_SPEC.md#library.
struct LibraryCollectionsView: View {
    let books: [Book]
    let downloadProgress: [Book.ID: Double]
    let authorFormat: AuthorDisplayFormat
    let files: BookFileStore?
    @Environment(\.appEnvironment) private var environment
    @AppStorage(StoredIDSet.libraryCollapsedKey) private var collapsed = StoredIDSet()
    @State private var memberships = CollectionMemberships()

    var body: some View {
        List {
            ForEach(LibrarySection.byCollection(books, memberships: memberships)) { section in
                CollapsibleBookSection(
                    title: title(of: section),
                    books: section.books,
                    isExpanded: Binding(
                        get: { !collapsed.ids.contains(section.id) },
                        set: { expanded in
                            if expanded {
                                collapsed.ids.remove(section.id)
                            } else {
                                collapsed.ids.insert(section.id)
                            }
                        }
                    ),
                    downloadProgress: downloadProgress,
                    authorFormat: authorFormat,
                    files: files
                )
            }
        }
        .listStyle(.insetGrouped)
        .task {
            guard let environment else { return }
            do {
                for try await latest in environment.repositories.collections.observeMemberships() {
                    memberships = latest
                }
            } catch {
                memberships = CollectionMemberships()
            }
        }
    }

    private func title(of section: LibrarySection) -> String {
        switch section.kind {
        case .collection(let collection): collection.name
        case .notInACollection: String(localized: "Not in a Collection")
        }
    }
}

/// A set of ids stored in `@AppStorage` as a JSON array.
struct StoredIDSet: RawRepresentable, Equatable {
    /// The library's collapsed sections.
    static let libraryCollapsedKey = "libraryCollapsedSections"

    var ids: Set<String>

    init(_ ids: Set<String> = []) {
        self.ids = ids
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        ids = Set(decoded)
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
