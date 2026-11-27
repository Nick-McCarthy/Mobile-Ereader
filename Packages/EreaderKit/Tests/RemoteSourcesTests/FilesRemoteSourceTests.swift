import Foundation
import Testing

@testable import RemoteSources

@Suite("iCloud Drive / Files source")
struct FilesRemoteSourceTests {
    // MARK: Linking

    @Test("link() keeps a bookmark to the picked folder and labels the account with its name")
    func linkWithPicker() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let source = FilesRemoteSource(bookmark: nil, picker: FixedPicker(url: tree.root))

        let account = try await source.link()
        #expect(account.label == tree.root.lastPathComponent)
        #expect(await source.bookmark != nil)
    }

    @Test("Without a picker, link() is cancelled")
    func linkWithoutPicker() async {
        let source = FilesRemoteSource(bookmark: nil)
        await #expect(throws: RemoteSourceError.cancelled) { _ = try await source.link() }
    }

    @Test("unlink() forgets the folder and leaves its files alone")
    func unlink() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let source = try await tree.linkedSource()

        await source.unlink()
        #expect(await source.bookmark == nil)
        #expect(FileManager.default.fileExists(atPath: tree.url("a.epub").path))
        await #expect(throws: RemoteSourceError.needsRelink) { _ = try await source.listFolders(in: nil) }
    }

    @Test("A folder that no longer exists needs re-linking")
    func missingRootNeedsRelink() async throws {
        let tree = try TempTree()
        let source = try await tree.linkedSource()
        tree.remove()

        await #expect(throws: RemoteSourceError.needsRelink) {
            _ = try await collect(source.enumerateEPUBs(under: .root, since: nil))
        }
    }

    @Test("No bookmark needs re-linking")
    func noBookmarkNeedsRelink() async {
        let source = FilesRemoteSource(bookmark: nil)
        await #expect(throws: RemoteSourceError.needsRelink) {
            _ = try await collect(source.enumerateEPUBs(under: .root, since: nil))
        }
    }

    // MARK: Listing

    @Test("Lists every EPUB recursively, mapping iCloud placeholders and skipping hidden items")
    func enumerateAll() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let source = try await tree.linkedSource()

        let changes = try await collect(source.enumerateEPUBs(under: .root, since: nil))
        #expect(changes.first == .reset)
        guard case .cursor = changes.last else {
            Issue.record("the listing must end with a cursor")
            return
        }
        let files = changes.compactMap { change -> RemoteFile? in
            if case .upsert(let file) = change { return file }
            return nil
        }
        // Files stream in walk order, which the file system decides.
        #expect(files.map(\.remoteId).sorted() == ["Fiction/b.EPUB", "Fiction/c.epub", "Sci-Fi/Deep/f.epub", "a.epub"])

        let rootName = tree.root.lastPathComponent
        let book = try #require(files.first { $0.remoteId == "a.epub" })
        #expect(book.name == "a.epub")
        #expect(book.displayPath == "/\(rootName)/a.epub")
        #expect(book.size == 5)
        #expect(book.modifiedAt != nil)

        let placeholder = try #require(files.first { $0.remoteId == "Fiction/c.epub" })
        #expect(placeholder.name == "c.epub")
        #expect(placeholder.size == nil, "a placeholder's own size isn't the book's")
    }

    @Test("A sub-folder lists only its books, with ids still relative to the picked folder")
    func enumerateSubfolder() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let source = try await tree.linkedSource()
        let fiction = RemoteFolder(id: "Fiction", name: "Fiction", displayPath: "/Fiction")

        let changes = try await collect(source.enumerateEPUBs(under: fiction, since: SyncCursor("files:1")))
        #expect(changes.first == .reset, "every listing is a full one")
        let ids = changes.compactMap { change -> String? in
            if case .upsert(let file) = change { return file.remoteId }
            return nil
        }
        #expect(ids.sorted() == ["Fiction/b.EPUB", "Fiction/c.epub"])
    }

    @Test("A downloaded file replaces its leftover placeholder")
    func downloadedFileWinsOverPlaceholder() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("Fiction/c.epub", "book")
        let source = try await tree.linkedSource()

        let changes = try await collect(source.enumerateEPUBs(under: .root, since: nil))
        let matches = changes.compactMap { change -> RemoteFile? in
            if case .upsert(let file) = change, file.remoteId == "Fiction/c.epub" { return file }
            return nil
        }
        #expect(matches.count == 1)
        #expect(matches.first?.size == 4)
    }

    // A stale bookmark can't be made in a test: only the system marks one stale (after a volume or folder
    // move), so `resolveRoot`'s refresh branch is checked by review, not by a test.

    @Test("A book deleted between listings is missing from the next one, which starts with reset")
    func deletedBetweenListings() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let source = try await tree.linkedSource()
        _ = try await tree.file("a.epub", from: source)

        try FileManager.default.removeItem(at: tree.url("a.epub"))
        let changes = try await collect(source.enumerateEPUBs(under: .root, since: SyncCursor("files:1")))
        #expect(changes.first == .reset, "reset lets the sync engine drop books the listing no longer has")
        let ids = changes.compactMap { change -> String? in
            if case .upsert(let file) = change { return file.remoteId }
            return nil
        }
        #expect(!ids.contains("a.epub"))
        #expect(ids.contains("Fiction/b.EPUB"))
    }

    @Test("The walk stops at the next item once its task is cancelled")
    func walkChecksCancellationPerItem() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        for index in 0..<200 {
            try tree.write("Many/book\(index).epub", "x")
        }
        let root = tree.root
        let task = Task { () -> Int in
            var visited = 0
            do {
                try FilesListing.epubs(under: root, root: root) { _ in
                    visited += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            } catch is CancellationError {
                return visited
            }
            return -1
        }
        #expect(try await task.value == 1, "the walk must throw at the first item after cancellation")
    }

    @Test("Stopping early ends a listing of a large tree")
    func stoppingEarlyEndsTheStream() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        for index in 0..<500 {
            try tree.write("Many/book\(index).epub", "x")
        }
        let source = try await tree.linkedSource()

        var upserts = 0
        for try await change in source.enumerateEPUBs(under: .root, since: nil) {
            if case .upsert = change { upserts += 1 }
            if upserts == 3 { break }
        }
        #expect(upserts == 3)
    }

    @Test("The version changes when the file's content changes")
    func versionChanges() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let source = try await tree.linkedSource()
        let before = try await tree.file("a.epub", from: source)

        try tree.write("a.epub", "a longer book")
        let after = try await tree.file("a.epub", from: source)
        #expect(before.version != after.version)
    }

    @Test("Folders list visible sub-folders, sorted as Files sorts them")
    func listFolders() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let source = try await tree.linkedSource()
        let rootName = tree.root.lastPathComponent

        let top = try await source.listFolders(in: nil)
        #expect(top.map(\.id) == ["Fiction", "Sci-Fi"])
        #expect(top.first?.displayPath == "/\(rootName)/Fiction")

        let nested = try await source.listFolders(in: RemoteFolder(id: "Sci-Fi", name: "Sci-Fi", displayPath: ""))
        #expect(nested == [RemoteFolder(id: "Sci-Fi/Deep", name: "Deep", displayPath: "/\(rootName)/Sci-Fi/Deep")])

        await #expect(throws: RemoteSourceError.notFound) {
            _ = try await source.listFolders(in: RemoteFolder(id: "Gone", name: "Gone", displayPath: ""))
        }
    }

    // MARK: Reading

    @Test("Files have no ranged reader")
    func noRangedReads() {
        let source = FilesRemoteSource(bookmark: nil)
        let file = RemoteFile(remoteId: "a.epub", displayPath: "", name: "a", size: 1, version: "v", modifiedAt: nil)
        #expect(source.byteRangeReader(for: file) == nil)
    }

    @Test("download copies the file, replacing anything at the destination")
    func download() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let source = try await tree.linkedSource()
        let file = try await tree.file("Sci-Fi/Deep/f.epub", from: source)
        let destination = tree.scratch.appendingPathComponent("copy.epub")
        try Data("old".utf8).write(to: destination)
        let progress = ProgressLog()

        try await source.download(file, to: destination) { value in progress.append(value) }
        #expect(try Data(contentsOf: destination) == Data("deep!".utf8))
        #expect(progress.values == [0, 1])
        let original = tree.url("Sci-Fi/Deep/f.epub")
        #expect(FileManager.default.fileExists(atPath: original.path), "the source is untouched")
    }

    @Test("download of a missing or escaping path is notFound", arguments: ["missing.epub", "../outside.epub"])
    func downloadNotFound(remoteId: String) async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try Data("secret".utf8).write(to: tree.scratch.appendingPathComponent("outside.epub"))
        let source = try await tree.linkedSource()
        let file = RemoteFile(
            remoteId: remoteId,
            displayPath: "",
            name: "x.epub",
            size: nil,
            version: "v",
            modifiedAt: nil
        )
        let destination = tree.scratch.appendingPathComponent("copy.epub")

        await #expect(throws: RemoteSourceError.notFound) {
            try await source.download(file, to: destination) { _ in }
        }
    }

    // MARK: Helpers

    @Test(
        "Placeholder and hidden names",
        arguments: [
            ("book.epub", "book.epub"), ("Book.EPUB", "Book.EPUB"), (".book.epub.icloud", "book.epub"),
            (".notes.txt.icloud", nil), (".book.epub", nil), ("book.txt", nil), (".epub.icloud", nil),
            ("..icloud", nil),
        ] as [(String, String?)]
    )
    func epubNames(name: String, expected: String?) {
        #expect(FilesListing.epubName(forFileNamed: name) == expected)
    }
}

// MARK: - Fixtures

/// A temporary folder tree standing in for a picked iCloud Drive folder:
///
///     Books/a.epub, Books/notes.txt, Books/.e.epub
///     Books/Fiction/b.EPUB, Books/Fiction/.c.epub.icloud (placeholder)
///     Books/Sci-Fi/Deep/f.epub, Books/.hidden/d.epub
private struct TempTree {
    let scratch: URL
    let root: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = scratch.appendingPathComponent("Books", isDirectory: true)
        try write("a.epub", "hello")
        try write("notes.txt", "not a book")
        try write(".e.epub", "hidden")
        try write("Fiction/b.EPUB", "bee")
        try write("Fiction/.c.epub.icloud", "placeholder plist")
        try write("Sci-Fi/Deep/f.epub", "deep!")
        try write(".hidden/d.epub", "hidden folder")
    }

    func url(_ path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    func write(_ path: String, _ contents: String) throws {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func linkedSource() async throws -> FilesRemoteSource {
        let source = FilesRemoteSource(bookmark: nil)
        try await source.link(folderAt: root)
        return source
    }

    func file(_ remoteId: String, from source: FilesRemoteSource) async throws -> RemoteFile {
        let changes = try await collect(source.enumerateEPUBs(under: .root, since: nil))
        for case .upsert(let file) in changes where file.remoteId == remoteId {
            return file
        }
        throw RemoteSourceError.notFound
    }
}

private struct FixedPicker: FolderPicking {
    let url: URL

    @MainActor func pickFolder() async throws -> URL {
        url
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] { lock.withLock { storage } }

    func append(_ value: Double) {
        lock.withLock { storage.append(value) }
    }
}

private func collect(_ stream: RemoteChangeStream) async throws -> [RemoteChange] {
    var changes: [RemoteChange] = []
    for try await change in stream {
        changes.append(change)
    }
    return changes
}
