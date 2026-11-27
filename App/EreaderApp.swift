import SwiftUI

@main
struct EreaderApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The app's three top-level tabs. See docs/UI_SPEC.md.
struct RootView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            CollectionsView()
                .tabItem { Label("Collections", systemImage: "rectangle.stack") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
