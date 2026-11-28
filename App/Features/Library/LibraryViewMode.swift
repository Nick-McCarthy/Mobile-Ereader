import SwiftUI

/// How the library lays out its books, chosen from the *View* menu and kept in `@AppStorage`.
/// See docs/UI_SPEC.md#library.
enum LibraryViewMode: String, CaseIterable, Identifiable {
    case grid
    case list
    case collections

    static let storageKey = "libraryViewMode"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        case .collections: "Collections"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        case .collections: "rectangle.stack"
        }
    }
}

/// The toolbar's *View* menu.
struct LibraryViewModeMenu: View {
    @Binding var mode: LibraryViewMode

    var body: some View {
        Menu {
            Picker("View", selection: $mode) {
                ForEach(LibraryViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
        } label: {
            Label("View", systemImage: mode.systemImage)
        }
    }
}
