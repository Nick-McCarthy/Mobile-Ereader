import Persistence
import SwiftUI

/// Settings tab: book sources and sync (P2.8); library options, storage, and privacy arrive in Phase 4.
struct SettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var sources: [LibrarySource] = []

    var body: some View {
        NavigationStack {
            Form {
                BookSourcesSection(sources: sources)
                Section {
                    LabeledContent("Version", value: Self.appVersion)
                } header: {
                    Text("About").foregroundStyle(.secondaryText)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SourceRoute.self) { route in
                SourceDetailView(sourceId: route.id)
            }
        }
        .task {
            guard let environment else { return }
            do {
                for try await latest in environment.repositories.sources.observeSources() {
                    sources = latest
                }
            } catch {
                sources = []
            }
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
}
