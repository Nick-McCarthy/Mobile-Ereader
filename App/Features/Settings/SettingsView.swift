import SwiftUI

/// Settings tab: book sources and sync, library options, storage, privacy (action plan P2.8, Phase 4).
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("Book Sources") {
                    Label("iCloud Drive / Files", systemImage: "icloud")
                    Label("Dropbox", systemImage: "shippingbox")
                    Label("OneDrive", systemImage: "cloud")
                }
                Section("About") {
                    LabeledContent("Version", value: Self.appVersion)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
}
