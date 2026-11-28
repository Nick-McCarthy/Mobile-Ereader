import Core
import LibraryServices
import Observation
import Persistence

/// Runs syncs for Settings (*Sync Now*, *Sync This Source*), pull-to-refresh, and the library banner, and keeps
/// the latest progress of each source for them to show. One sync at a time. See docs/UI_SPEC.md#settings.
@MainActor
@Observable
final class SyncCoordinator {
    /// The latest progress of each source in the current (or last) sync.
    private(set) var progress: [LibrarySource.ID: SyncProgress] = [:]
    private(set) var isSyncing = false
    private var running: Task<Void, Never>?

    private let engine: SyncEngine
    private let bookSources: BookSources

    init(engine: SyncEngine, bookSources: BookSources) {
        self.engine = engine
        self.bookSources = bookSources
    }

    /// The source being synced right now, if any, for the banner.
    var current: SyncProgress? {
        progress.values.first { progress in
            if case .finished = progress.phase { return false }
            return true
        }
    }

    /// Syncs every linked source, or only `sourceId`, and returns when it's done. Does nothing while a sync is
    /// already running.
    func sync(only sourceId: LibrarySource.ID? = nil) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            running = nil
        }
        let linked = (try? await bookSources.linkedSources()) ?? []
        let targets = bookSources.syncTargets(for: linked.filter { sourceId == nil || $0.id == sourceId })
        guard !targets.isEmpty else { return }
        progress = [:]

        let engine = engine
        let task = Task {
            for await update in engine.run(targets) {
                progress[update.sourceId] = update
            }
        }
        running = task
        await task.value
        await bookSources.saveRefreshedBookmarks(targets)
    }

    /// Stops the running sync. What was saved so far stays; the next sync carries on from there.
    func cancel() {
        running?.cancel()
    }
}
