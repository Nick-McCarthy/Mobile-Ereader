import Core
import LibraryServices
import Persistence
import RemoteSources
import SwiftUI
import UniformTypeIdentifiers

/// A linked source: its folder and sync state, *Sync This Source*, *Change Folder*, and *Unlink* with a
/// confirmation that states the outcome. See docs/UI_SPEC.md#settings and docs/REMOTE_SOURCES.md.
struct SourceDetailView: View {
    let sourceId: LibrarySource.ID
    @Environment(\.appEnvironment) private var environment
    @Environment(SyncCoordinator.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var source: LibrarySource?
    @State private var pickingFolder = false
    @State private var unlinkPreview: UnlinkPreview?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let source {
                details(source)
                actions(source)
            }
        }
        .navigationTitle(source?.kind.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await changeFolder(to: url) }
        }
        .confirmationDialog(
            "Unlink \(source?.kind.serviceName ?? "")?",
            isPresented: Binding(get: { unlinkPreview != nil }, set: { if !$0 { unlinkPreview = nil } }),
            titleVisibility: .visible,
            presenting: unlinkPreview
        ) { _ in
            Button("Unlink", role: .destructive) {
                Task { await unlink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { preview in
            Text(
                """
                ^[\(preview.notDownloaded) book](inflect: true) not downloaded will be removed from your library. \
                ^[\(preview.downloaded) downloaded book](inflect: true) will stay. \
                Your files in \(source?.kind.serviceName ?? "") won't be changed.
                """
            )
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            guard let environment else { return }
            do {
                for try await sources in environment.repositories.sources.observeSources() {
                    source = sources.first { $0.id == sourceId }
                    if source == nil { dismiss() }
                }
            } catch {
                source = nil
            }
        }
    }

    @ViewBuilder
    private func details(_ source: LibrarySource) -> some View {
        Section {
            LabeledContent("Folder", value: source.rootDisplayPath)
            if let progress = sync.progress[source.id], let running = SyncStatusText.running(progress) {
                LabeledContent("Sync", value: running)
            } else if let synced = source.lastSyncedAt {
                LabeledContent("Last Synced", value: synced.formatted(.relative(presentation: .named)))
            } else {
                LabeledContent("Last Synced", value: String(localized: "Not yet"))
            }
            if let progress = sync.progress[source.id], case .finished = progress.phase {
                LabeledContent("Books Found", value: progress.found, format: .number)
                if progress.errors > 0 {
                    LabeledContent("Couldn't Read", value: progress.errors, format: .number)
                }
            }
        } footer: {
            switch source.status {
            case .needsRelink:
                Text("The app lost access to this folder. Choose it again to keep syncing.")
                    .foregroundStyle(.secondaryText)
            case .error:
                Text(source.lastSyncError ?? String(localized: "The last sync didn't finish."))
                    .foregroundStyle(.secondaryText)
            case .ok:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func actions(_ source: LibrarySource) -> some View {
        Section {
            if sync.isSyncing {
                Button("Cancel Sync", role: .destructive) { sync.cancel() }
            } else {
                Button("Sync This Source", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await sync.sync(only: source.id) }
                }
            }
            Button(
                source.status == .needsRelink ? LocalizedStringKey("Choose Folder Again…") : "Change Folder…",
                systemImage: "folder"
            ) {
                pickingFolder = true
            }
            .disabled(sync.isSyncing)
        }
        Section {
            Button("Unlink…", systemImage: "link", role: .destructive) {
                Task { await prepareUnlink() }
            }
            .disabled(sync.isSyncing)
        }
    }

    private func changeFolder(to url: URL) async {
        guard let environment else { return }
        do {
            try await environment.bookSources.changeFolder(of: sourceId, to: url)
            await sync.sync(only: sourceId)
        } catch {
            errorMessage = String(localized: "Choose a folder you can open in the Files app, then try again.")
        }
    }

    private func prepareUnlink() async {
        guard let environment else { return }
        unlinkPreview = try? await environment.unlinker.preview(sourceId: sourceId)
    }

    private func unlink() async {
        guard let environment, let source else { return }
        do {
            let remote = environment.bookSources.remote(for: source)
            // The source list observed above then drops this source and closes the screen.
            try await environment.unlinker.unlink(sourceId: sourceId, remote: remote)
        } catch {
            errorMessage = String(localized: "The source couldn't be unlinked. Try again.")
        }
    }
}
