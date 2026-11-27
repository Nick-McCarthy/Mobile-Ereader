import Core
import Foundation

/// Shows the system folder picker. The app provides the iOS implementation (a
/// `UIDocumentPickerViewController` for `.folder`); tests provide a fixed URL.
public protocol FolderPicking: Sendable {
    /// The folder the user picked. Throws `RemoteSourceError.cancelled` if they back out.
    @MainActor func pickFolder() async throws -> URL
}

/// The "iCloud Drive / Files" source: a folder the user picked in the Files picker, which may belong to
/// iCloud Drive or any other file provider. No sign-in; access is kept with a bookmark.
/// See docs/REMOTE_SOURCES.md#icloud-drive--files-specifics.
///
/// Remote ids and folder ids are paths relative to the picked folder. Every listing is a full one, so the
/// stream always starts with `.reset`.
public actor FilesRemoteSource: RemoteSource {
    public nonisolated let kind = SourceKind.iCloud

    /// Bookmark of the picked folder, for `library_source.rootBookmark`. Set by `link()`, refreshed when
    /// the system reports it stale, and cleared by `unlink()`; save it after each of those.
    public private(set) var bookmark: Data?
    private let picker: (any FolderPicking)?

    public init(bookmark: Data?, picker: (any FolderPicking)? = nil) {
        self.bookmark = bookmark
        self.picker = picker
    }

    // MARK: Linking

    /// Shows the folder picker and keeps a bookmark to the chosen folder. The account label is its name.
    public func link() async throws -> LinkedAccount {
        guard let picker else { throw RemoteSourceError.cancelled }
        let url = try await picker.pickFolder()
        try link(folderAt: url)
        return LinkedAccount(label: url.lastPathComponent)
    }

    /// Keeps a bookmark to `url`, a folder from the picker (still security-scoped).
    public func link(folderAt url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard FilesListing.isDirectory(url) else { throw RemoteSourceError.notFound }
        bookmark = try url.bookmarkData()
    }

    /// Forgets the folder. The folder and its files are not touched.
    public func unlink() {
        bookmark = nil
    }

    // MARK: Listing

    public func listFolders(in folder: RemoteFolder?) throws -> [RemoteFolder] {
        try withRoot { root in
            let parentId = folder?.id ?? ""
            let parent = try FilesListing.url(for: parentId, in: root)
            guard FilesListing.isDirectory(parent) else { throw RemoteSourceError.notFound }
            return try FilesListing.subfolders(of: parent, id: parentId, rootName: root.lastPathComponent)
        }
    }

    public nonisolated func enumerateEPUBs(
        under root: RemoteFolder,
        since cursor: SyncCursor?
    ) -> RemoteChangeStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let files = try await self.listEPUBs(under: root)
                    continuation.yield(.reset)
                    for file in files {
                        try Task.checkCancellation()
                        continuation.yield(.upsert(file))
                    }
                    continuation.yield(.cursor(SyncCursor("files:\(Int(Date().timeIntervalSince1970))")))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: RemoteSourceError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func listEPUBs(under folder: RemoteFolder) throws -> [RemoteFile] {
        try withRoot { root in
            let start = try FilesListing.url(for: folder.id, in: root)
            guard FilesListing.isDirectory(start) else { throw RemoteSourceError.notFound }
            return try FilesListing.epubs(under: start, root: root)
        }
    }

    // MARK: Reading

    /// Files are read whole: `download` makes the provider fetch the file.
    public nonisolated func byteRangeReader(for file: RemoteFile) -> (any ByteRangeReading)? {
        nil
    }

    /// Copies the file to `destination` with a coordinated read, which makes iCloud (or another provider)
    /// fetch it first. If it wasn't on the device before, it is evicted again afterwards so syncing
    /// metadata doesn't fill the device; the app's own copy at `destination` is unaffected.
    public func download(
        _ file: RemoteFile,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let root = try resolveRoot()
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }

        let source = try FilesListing.url(for: file.remoteId, in: root)
        let placeholder = FilesListing.placeholderURL(for: source)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) || fileManager.fileExists(atPath: placeholder.path) else {
            throw RemoteSourceError.notFound
        }
        let wasLocal = FilesListing.isDownloaded(source)
        progress(0)
        try await Self.coordinatedCopy(from: source, to: destination)
        if !wasLocal {
            try? fileManager.evictUbiquitousItem(at: source)
        }
        progress(1)
    }

    private static func coordinatedCopy(from source: URL, to destination: URL) async throws {
        let intent = NSFileAccessIntent.readingIntent(with: source, options: .withoutChanges)
        let queue = OperationQueue()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSFileCoordinator().coordinate(with: [intent], queue: queue) { error in
                if let error {
                    continuation.resume(throwing: Self.mapped(error))
                    return
                }
                do {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.copyItem(at: intent.url, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: Self.mapped(error))
                }
            }
        }
    }

    private static func mapped(_ error: any Error) -> any Error {
        let nsError = error as NSError
        let missing = [NSFileNoSuchFileError, NSFileReadNoSuchFileError]
        if nsError.domain == NSCocoaErrorDomain, missing.contains(nsError.code) { return RemoteSourceError.notFound }
        return error
    }

    // MARK: Folder access

    /// Runs `body` with the picked folder's URL while its security scope is open.
    private func withRoot<T>(_ body: (URL) throws -> T) throws -> T {
        let root = try resolveRoot()
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        guard FilesListing.isDirectory(root) else { throw RemoteSourceError.needsRelink }
        return try body(root)
    }

    /// Resolves the bookmark, re-creating it if stale. A missing or broken bookmark means re-link.
    private func resolveRoot() throws -> URL {
        guard let bookmark else { throw RemoteSourceError.needsRelink }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else {
            throw RemoteSourceError.needsRelink
        }
        if isStale {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData() { self.bookmark = fresh }
        }
        return url
    }
}
