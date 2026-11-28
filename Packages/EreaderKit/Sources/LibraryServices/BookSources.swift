import Core
import Foundation
import Persistence
import RemoteSources

/// The linked book sources and their adapters, for Settings and sync (action plan P2.8).
///
/// This version reads iCloud Drive / Files only; Dropbox and OneDrive arrive with their adapters (P2.5, P2.6).
public struct BookSources: Sendable {
    let sources: any LibrarySourceRepository

    public init(sources: any LibrarySourceRepository) {
        self.sources = sources
    }

    /// Whether this version can link and read the service.
    public static func isAvailable(_ kind: SourceKind) -> Bool {
        kind == .iCloud
    }

    /// The services the user can link, in the order Settings lists them.
    public static let linkableKinds: [SourceKind] = [.iCloud, .dropbox, .oneDrive]

    /// Every linked source, in Settings order.
    public func linkedSources() async throws -> [LibrarySource] {
        var linked: [LibrarySource] = []
        for kind in Self.linkableKinds {
            if let source = try await sources.source(kind: kind) { linked.append(source) }
        }
        return linked
    }

    /// The adapter that reads `source`, or nil if this version can't read that service.
    public func remote(for source: LibrarySource) -> (any RemoteSource)? {
        switch source.kind {
        case .iCloud: FilesRemoteSource(bookmark: source.rootBookmark)
        case .dropbox, .oneDrive, .local: nil
        }
    }

    /// What `SyncEngine` needs for each source this version can read.
    public func syncTargets(for linked: [LibrarySource]) -> [SyncTarget] {
        linked.compactMap { source in remote(for: source).map { SyncTarget(source: source, remote: $0) } }
    }

    /// Links the iCloud Drive / Files folder the user picked (a security-scoped URL from the folder picker).
    /// The folder's name is shown as the account; the folder is the whole root. Throws
    /// `RepositoryError.sourceAlreadyLinked` if a folder is linked already.
    @discardableResult
    @concurrent
    public func linkFolder(at url: URL) async throws -> LibrarySource {
        let remote = FilesRemoteSource(bookmark: nil)
        try await remote.link(folderAt: url)
        let name = url.lastPathComponent
        let source = LibrarySource(
            kind: .iCloud,
            accountLabel: name,
            rootId: "",
            rootBookmark: await remote.bookmark,
            rootDisplayPath: "/\(name)"
        )
        try await sources.addSource(source)
        return source
    }

    /// Points the linked iCloud source at another folder, or the same one again when access was lost
    /// (`needsRelink`). The next sync is a full listing; books not in the new folder are flagged missing.
    @concurrent
    public func changeFolder(of sourceId: LibrarySource.ID, to url: URL) async throws {
        let remote = FilesRemoteSource(bookmark: nil)
        try await remote.link(folderAt: url)
        try await sources.changeRoot(
            id: sourceId,
            rootId: "",
            rootBookmark: await remote.bookmark,
            rootDisplayPath: "/\(url.lastPathComponent)"
        )
    }

    /// After a sync: saves the bookmark an iCloud adapter re-created because the old one was stale.
    public func saveRefreshedBookmarks(_ targets: [SyncTarget]) async {
        for target in targets {
            guard let files = target.remote as? FilesRemoteSource else { continue }
            let bookmark = await files.bookmark
            if let bookmark, bookmark != target.source.rootBookmark {
                try? await sources.saveRootBookmark(id: target.source.id, bookmark: bookmark)
            }
        }
    }
}
