import Core
import SwiftUI

/// The toolbar's *Sort* menu: the sort key and its direction, both kept in `@AppStorage`. The order rules are in
/// docs/DATA_MODEL.md#display-rules; books without a value stay last in either direction.
struct LibrarySortMenu: View {
    @Binding var sort: LibrarySortOrder
    @Binding var reversed: Bool

    static let sortKey = "librarySort"
    static let reversedKey = "librarySortReversed"

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
            Picker("Order", selection: $reversed) {
                Text(sort.directionTitle(reversed: false)).tag(false)
                Text(sort.directionTitle(reversed: true)).tag(true)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}

extension LibrarySortOrder {
    var title: LocalizedStringKey {
        switch self {
        case .recentlyViewed: "Recently Viewed"
        case .title: "Title"
        case .author: "Author"
        case .publicationDate: "Publication Date"
        case .downloadState: "Downloaded"
        }
    }

    /// The name of each direction; `reversed: false` is the natural one listed in `LibrarySortOrder`.
    func directionTitle(reversed: Bool) -> LocalizedStringKey {
        switch (self, reversed) {
        case (.recentlyViewed, false): "Most Recent First"
        case (.recentlyViewed, true): "Least Recent First"
        case (.title, false), (.author, false): "A to Z"
        case (.title, true), (.author, true): "Z to A"
        case (.publicationDate, false): "Oldest First"
        case (.publicationDate, true): "Newest First"
        case (.downloadState, false): "Downloaded First"
        case (.downloadState, true): "Not Downloaded First"
        }
    }
}
