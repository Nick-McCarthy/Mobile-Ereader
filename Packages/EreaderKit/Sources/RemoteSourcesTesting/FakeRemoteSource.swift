import Core
import Foundation
import RemoteSources

/// An in-memory `RemoteSource` for tests: a configurable file tree with pagination, change cursors,
/// deletions, rate limiting, and auth expiry. Never shipped in the app. See docs/REMOTE_SOURCES.md#testing.
///
/// Paths are absolute ("/Books/Earthsea.epub") and double as remote ids and folder ids.
public actor FakeRemoteSource: RemoteSource {
    public nonisolated let kind: SourceKind

    /// Upserts per page. Each page is fetched separately, so failures can land between pages.
    public private(set) var pageSize = 2
    public private(set) var isLinked = false
    public private(set) var accountLabel: String?
    /// How many enumerations and downloads have started, for asserting retries.
    public private(set) var enumerationCount = 0
    public private(set) var rangeReadCount = 0

    private struct Item {
        var file: RemoteFile
        var data: Data
        var revision: Int
    }

    private var items: [String: Item] = [:]
    private var removals: [(remoteId: String, revision: Int)] = []
    private var revision = 0
    /// Cursors older than this revision are rejected, like a Dropbox `reset` or a Graph `410 Gone`.
    private var oldestValidRevision = 0
    private var pendingRateLimits = 0
    private var rateLimitRetryAfter: Double?
    private var authExpired = false
    private var failAfterPages: Int?

    public init(kind: SourceKind = .dropbox, accountLabel: String? = "reader@example.com") {
        self.kind = kind
        self.accountLabel = accountLabel
    }

    // MARK: Configuring the tree

    /// Adds or replaces a file. Replacing it gives it a new `version`.
    @discardableResult
    public func putFile(_ path: String, data: Data = Data("epub".utf8), modifiedAt: Date? = nil) -> RemoteFile {
        revision += 1
        let name = String(path.split(separator: "/").last ?? "")
        let file = RemoteFile(
            remoteId: path,
            displayPath: path,
            name: name,
            size: Int64(data.count),
            version: "v\(revision)",
            modifiedAt: modifiedAt
        )
        items[path] = Item(file: file, data: data, revision: revision)
        return file
    }

    public func removeFile(_ path: String) {
        guard items.removeValue(forKey: path) != nil else { return }
        revision += 1
        removals.append((remoteId: path, revision: revision))
    }

    public func setPageSize(_ size: Int) {
        pageSize = max(size, 1)
    }

    // MARK: Injecting failures

    /// The next `count` enumerations throw `.rateLimited` before listing anything.
    public func rateLimitNext(_ count: Int, retryAfter: Double? = nil) {
        pendingRateLimits = count
        rateLimitRetryAfter = retryAfter
    }

    /// Every call throws `.needsRelink` until `link()` succeeds again.
    public func expireAuth() {
        authExpired = true
    }

    /// Makes every cursor issued so far invalid, so the next sync gets `.reset` and a full listing.
    public func invalidateCursors() {
        oldestValidRevision = revision + 1
    }

    /// The next enumeration throws `.notFound` after sending this many pages (nil turns it off).
    public func failEnumeration(afterPages pages: Int?) {
        failAfterPages = pages
    }

    // MARK: RemoteSource

    public func link() async throws -> LinkedAccount {
        isLinked = true
        authExpired = false
        return LinkedAccount(label: accountLabel)
    }

    public func unlink() async throws {
        isLinked = false
    }

    public func listFolders(in folder: RemoteFolder?) async throws -> [RemoteFolder] {
        try checkAuth()
        let parent = folder?.id.isEmpty == false ? folder?.id ?? "" : ""
        var names = Set<String>()
        for path in items.keys {
            guard let relative = Self.relativePath(path, under: parent) else { continue }
            let components = relative.split(separator: "/")
            if components.count > 1 { names.insert(String(components[0])) }
        }
        return names.sorted().map { name in
            let path = "\(parent)/\(name)"
            return RemoteFolder(id: path, name: name, displayPath: path)
        }
    }

    public nonisolated func enumerateEPUBs(under root: RemoteFolder, since cursor: SyncCursor?) -> RemoteChangeStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let pages = try await self.beginEnumeration(under: root, since: cursor)
                    for (index, page) in pages.changes.enumerated() {
                        try Task.checkCancellation()
                        try await self.checkPageFailure(sentPages: index)
                        for change in page { continuation.yield(change) }
                    }
                    continuation.yield(.cursor(pages.cursor))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func byteRangeReader(for file: RemoteFile) -> (any ByteRangeReading)? {
        FakeByteRangeReader(source: self, remoteId: file.remoteId)
    }

    public func download(
        _ file: RemoteFile,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try checkAuth()
        guard let item = items[file.remoteId] else { throw RemoteSourceError.notFound }
        progress(0)
        try item.data.write(to: destination)
        progress(1)
    }

    // MARK: Internals

    private struct Listing {
        var changes: [[RemoteChange]]
        var cursor: SyncCursor
    }

    private func beginEnumeration(under root: RemoteFolder, since cursor: SyncCursor?) throws -> Listing {
        try checkAuth()
        enumerationCount += 1
        if pendingRateLimits > 0 {
            pendingRateLimits -= 1
            throw RemoteSourceError.rateLimited(retryAfter: rateLimitRetryAfter)
        }

        let listed = items.values.filter { Self.isListed($0.file, under: root) }
        let inRoot = listed.sorted { $0.file.remoteId < $1.file.remoteId }

        var changes: [RemoteChange]
        if let since = cursor.flatMap(Self.revision(of:)), since >= oldestValidRevision {
            changes = inRoot.filter { $0.revision > since }.map { .upsert($0.file) }
            let removed = removals.filter { removal in
                removal.revision > since && Self.relativePath(removal.remoteId, under: root.id) != nil
            }
            changes += removed.map { .removed(remoteId: $0.remoteId) }
        } else {
            changes = inRoot.map { .upsert($0.file) }
        }

        var pages = stride(from: 0, to: changes.count, by: pageSize).map { start in
            Array(changes[start..<min(start + pageSize, changes.count)])
        }
        let isFullListing = cursor.flatMap(Self.revision(of:)).map { $0 < oldestValidRevision } ?? true
        if isFullListing {
            if pages.isEmpty { pages = [[]] }
            pages[0].insert(.reset, at: 0)
        }
        return Listing(changes: pages, cursor: SyncCursor("rev:\(revision)"))
    }

    private func checkPageFailure(sentPages: Int) throws {
        guard let failAfterPages, sentPages >= failAfterPages else { return }
        self.failAfterPages = nil
        throw RemoteSourceError.notFound
    }

    fileprivate func bytes(of remoteId: String) throws -> Data {
        try checkAuth()
        guard let item = items[remoteId] else { throw RemoteSourceError.notFound }
        return item.data
    }

    fileprivate func countRangeRead() {
        rangeReadCount += 1
    }

    private func checkAuth() throws {
        if authExpired { throw RemoteSourceError.needsRelink }
    }

    private static func revision(of cursor: SyncCursor) -> Int? {
        guard cursor.rawValue.hasPrefix("rev:") else { return nil }
        return Int(cursor.rawValue.dropFirst(4))
    }

    /// EPUBs under `root` are listed; other files are ignored, as the real adapters do.
    private static func isListed(_ file: RemoteFile, under root: RemoteFolder) -> Bool {
        relativePath(file.remoteId, under: root.id) != nil && file.name.lowercased().hasSuffix(".epub")
    }

    /// `path` relative to the folder `root` (an absolute path, or "" for the whole drive), or nil if outside it.
    private static func relativePath(_ path: String, under root: String) -> String? {
        let prefix = root.isEmpty || root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

/// Ranged reads over a fake file's bytes, counted so tests can check how many requests a reader makes.
public struct FakeByteRangeReader: ByteRangeReading {
    let source: FakeRemoteSource
    let remoteId: String

    public func length() async throws -> Int64 {
        Int64(try await source.bytes(of: remoteId).count)
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        let data = try await source.bytes(of: remoteId)
        await source.countRangeRead()
        let lower = Int(max(range.lowerBound, 0))
        let upper = Int(min(range.upperBound, Int64(data.count)))
        guard lower < upper else { return Data() }
        return data.subdata(in: lower..<upper)
    }
}
