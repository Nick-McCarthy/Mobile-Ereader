import SwiftUI

@main
struct EreaderApp: App {
    @State private var environment: AppEnvironment?
    @State private var importController: BookImportController?
    @State private var syncCoordinator: SyncCoordinator?

    init() {
        do {
            let environment = try AppEnvironment.live()
            _environment = State(initialValue: environment)
            _importController = State(initialValue: BookImportController(importer: environment.importer))
            _syncCoordinator = State(
                initialValue: SyncCoordinator(engine: environment.syncEngine, bookSources: environment.bookSources)
            )
        } catch {
            // Leaves both nil, so the body shows the "Can't Open Library" message.
        }
    }

    var body: some Scene {
        WindowGroup {
            if let environment, let importController, let syncCoordinator {
                RootView()
                    .environment(\.appEnvironment, environment)
                    .environment(importController)
                    .environment(syncCoordinator)
                    // "Open in…" and Files-app taps on an EPUB (CFBundleDocumentTypes in Info.plist).
                    .onOpenURL { url in
                        Task { await importController.importBooks([url]) }
                    }
                    .task { await environment.prepareAtLaunch() }
            } else {
                ContentUnavailableView(
                    "Can't Open Library",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The library database couldn't be opened. Restart the app to try again.")
                )
            }
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
