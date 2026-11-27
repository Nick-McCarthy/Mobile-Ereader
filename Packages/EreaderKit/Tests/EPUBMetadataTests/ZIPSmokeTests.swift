import Foundation
import ReadiumZIPFoundation
import Testing

@Suite("ZIP support")
struct ZIPSmokeTests {
    @Test("ReadiumZIPFoundation writes a deflated entry and reads it back")
    func roundTrip() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        try Data(repeating: 0x41, count: 4096).write(to: directory.appendingPathComponent("chapter.xhtml"))
        let archiveURL = directory.appendingPathComponent("book.epub")

        let writer = try await Archive(url: archiveURL, accessMode: .create)
        try await writer.addEntry(with: "chapter.xhtml", relativeTo: directory, compressionMethod: .deflate)

        let reader = try await Archive(url: archiveURL, accessMode: .read)
        let found = try await reader.get("chapter.xhtml")
        let entry = try #require(found)
        #expect(entry.uncompressedSize == 4096)
    }
}
