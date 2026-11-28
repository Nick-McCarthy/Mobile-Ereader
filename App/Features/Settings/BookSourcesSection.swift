import Core
import LibraryServices
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// How Settings and the library name each service.
extension SourceKind {
    var displayName: LocalizedStringKey {
        switch self {
        case .iCloud: "iCloud Drive / Files"
        case .dropbox: "Dropbox"
        case .oneDrive: "OneDrive"
        case .local: "On This iPhone"
        }
    }

    /// The name inside a sentence, such as "Your files in iCloud Drive won't be changed."
    var serviceName: String {
        switch self {
        case .iCloud: String(localized: "iCloud Drive")
        case .dropbox: String(localized: "Dropbox")
        case .oneDrive: String(localized: "OneDrive")
        case .local: String(localized: "this iPhone")
        }
    }

    var systemImage: String {
        switch self {
        case .iCloud: "icloud"
        case .dropbox: "shippingbox"
        case .oneDrive: "cloud"
        case .local: "iphone"
        }
    }
}

/// Settings › Book Sources: one row per service, *Sync Now*, and the read-only promise. See docs/UI_SPEC.md#settings.
struct BookSourcesSection: View {
    let sources: [LibrarySource]
    @Environment(\.appEnvironment) private var environment
    @Environment(SyncCoordinator.self) private var sync
    @State private var pickingFolder = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            ForEach(BookSources.linkableKinds, id: \.self) { kind in
                row(for: kind)
            }
            syncButton
        } header: {
            Text("Book Sources")
        } footer: {
            Text(
                """
                Access is read-only: the app never changes your files, and nothing is sent anywhere except the \
                service you link. iCloud Drive / Files also works with other file providers you have installed, \
                such as Google Drive.
                """
            )
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await link(url) }
        }
        .alert(
            "Couldn't Link Folder",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func row(for kind: SourceKind) -> some View {
        if let source = sources.first(where: { $0.kind == kind }) {
            NavigationLink(value: SourceRoute(id: source.id)) {
                SourceRow(kind: kind, source: source, progress: sync.progress[source.id])
            }
        } else if BookSources.isAvailable(kind) {
            Button {
                pickingFolder = true
            } label: {
                SourceRow(kind: kind, source: nil, progress: nil)
            }
            .accessibilityHint("Choose a folder of books to link")
        } else {
            SourceRow(kind: kind, source: nil, progress: nil, available: false)
        }
    }

    @ViewBuilder
    private var syncButton: some View {
        if sync.isSyncing {
            Button("Cancel Sync", role: .destructive) { sync.cancel() }
        } else {
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                Task { await sync.sync() }
            }
            .disabled(!sources.contains { BookSources.isAvailable($0.kind) })
        }
    }

    private func link(_ url: URL) async {
        guard let environment else { return }
        do {
            let source = try await environment.bookSources.linkFolder(at: url)
            await sync.sync(only: source.id)
        } catch {
            errorMessage = String(localized: "Choose a folder you can open in the Files app, then try again.")
        }
    }
}

/// Opens a linked source's detail screen.
struct SourceRoute: Hashable {
    var id: LibrarySource.ID
}

/// A service in Settings: its name, and what's linked (folder, last sync, problems) or its sync progress.
struct SourceRow: View {
    let kind: SourceKind
    let source: LibrarySource?
    let progress: SyncProgress?
    var available = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .frame(width: 28)
                .foregroundStyle(available ? Color.accentColor : Color.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .foregroundStyle(available ? Color.primary : Color.secondaryText)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 0)
            if source?.status == .needsRelink || source?.status == .error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Needs Attention")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        guard available else { return String(localized: "Coming in a later version") }
        guard let source else { return String(localized: "Not linked") }
        if let progress, let text = SyncStatusText.running(progress) { return text }
        switch source.status {
        case .needsRelink: return String(localized: "Choose the folder again to keep syncing")
        case .error: return source.lastSyncError ?? String(localized: "The last sync didn't finish")
        case .ok: break
        }
        guard let synced = source.lastSyncedAt else {
            return String(localized: "\(source.rootDisplayPath) · Not synced yet")
        }
        let when = synced.formatted(.relative(presentation: .named))
        return String(localized: "\(source.rootDisplayPath) · Synced \(when)")
    }
}

/// Words for a sync in progress, shared by Settings and the library banner.
enum SyncStatusText {
    /// "Looking for books…" or "Reading 12 of 40", or nil once the sync has finished.
    static func running(_ progress: SyncProgress) -> String? {
        switch progress.phase {
        case .listing:
            return String(localized: "Looking for books…")
        case .fetchingMetadata:
            return String(localized: "Reading \(progress.processed) of \(progress.toProcess)")
        case .finished:
            return nil
        }
    }
}
