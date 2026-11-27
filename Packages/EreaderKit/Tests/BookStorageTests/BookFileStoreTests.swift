import Foundation
import Testing

@testable import BookStorage

@Suite("Book file store")
struct BookFileStoreTests {
    let root: URL
    let store: BookFileStore

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = BookFileStore(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("A local copy lands in Books/local under the book id, and can be removed")
    func copyLocalBook() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Picked Book.epub")
        try Data("epub bytes".utf8).write(to: source)

        let path = try store.copyLocalBook(from: source, bookId: "B1")
        #expect(path == "Books/local/B1.epub")
        #expect(try Data(contentsOf: store.url(forBookPath: path)) == Data("epub bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))

        try store.removeBook(atPath: path)
        #expect(!FileManager.default.fileExists(atPath: store.url(forBookPath: path).path(percentEncoded: false)))
        try store.removeBook(atPath: path)  // Removing again is not an error.
    }

    @Test("Covers are written to Caches/Covers")
    func saveCover() throws {
        defer { cleanUp() }
        let path = try store.saveCover(Data([0xFF, 0xD8]), bookId: "B1")
        #expect(path == "B1.jpg")
        #expect(store.url(forCoverPath: path).path(percentEncoded: false).hasSuffix("Caches/Covers/B1.jpg"))
        #expect(try Data(contentsOf: store.url(forCoverPath: path)) == Data([0xFF, 0xD8]))
        try store.removeCover(atPath: path)
    }

    @Test("Book ids that could name another directory are refused", arguments: ["", "../x", "a/b", "a.b"])
    func unsafeIds(bookId: String) {
        #expect(throws: (any Error).self) { _ = try BookFileStore.safeFileName(bookId) }
    }
}
