import Foundation
import RemoteSources
import RemoteSourcesTesting
import Testing

/// Checks that the fake follows the `RemoteSource` contract the sync engine relies on.
@Suite("Fake remote source")
struct FakeRemoteSourceTests {
    private func collect(_ stream: RemoteChangeStream) async throws -> [RemoteChange] {
        var changes: [RemoteChange] = []
        for try await change in stream { changes.append(change) }
        return changes
    }

    private func makeSource() async -> FakeRemoteSource {
        let source = FakeRemoteSource()
        await source.putFile("/Books/Fiction/Earthsea.epub")
        await source.putFile("/Books/Fiction/Nested/Dune.epub")
        await source.putFile("/Books/notes.txt")
        await source.putFile("/Other/Outside.epub")
        return source
    }

    @Test("A full listing starts with reset, lists EPUBs under the root recursively, and ends with a cursor")
    func fullListing() async throws {
        let source = await makeSource()
        let root = RemoteFolder(id: "/Books", name: "Books", displayPath: "/Books")
        let changes = try await collect(source.enumerateEPUBs(under: root, since: nil))

        #expect(changes.first == .reset)
        let upserted = changes.compactMap { change -> String? in
            if case .upsert(let file) = change { return file.remoteId }
            return nil
        }
        #expect(upserted == ["/Books/Fiction/Earthsea.epub", "/Books/Fiction/Nested/Dune.epub"])
        guard case .cursor = changes.last else {
            Issue.record("listing should end with a cursor")
            return
        }
    }

    @Test("A saved cursor yields only changes since then, including removals")
    func incremental() async throws {
        let source = await makeSource()
        let first = try await collect(source.enumerateEPUBs(under: .root, since: nil))
        guard case .cursor(let cursor) = first.last else {
            Issue.record("missing cursor")
            return
        }

        let changed = await source.putFile("/Books/Fiction/Earthsea.epub", data: Data("v2".utf8))
        await source.removeFile("/Other/Outside.epub")
        let second = try await collect(source.enumerateEPUBs(under: .root, since: cursor))

        #expect(!second.contains(.reset))
        #expect(Array(second.dropLast()) == [.upsert(changed), .removed(remoteId: "/Other/Outside.epub")])
    }

    @Test("An invalidated cursor falls back to a full listing")
    func invalidCursor() async throws {
        let source = await makeSource()
        let first = try await collect(source.enumerateEPUBs(under: .root, since: nil))
        guard case .cursor(let cursor) = first.last else {
            Issue.record("missing cursor")
            return
        }
        await source.invalidateCursors()
        let second = try await collect(source.enumerateEPUBs(under: .root, since: cursor))
        #expect(second.first == .reset)
        #expect(second.filter { if case .upsert = $0 { true } else { false } }.count == 3)
    }

    @Test("Rate limits, auth expiry, and mid-listing failures surface as RemoteSourceError")
    func failures() async throws {
        let source = await makeSource()

        await source.rateLimitNext(1, retryAfter: 2)
        await #expect(throws: RemoteSourceError.rateLimited(retryAfter: 2)) {
            _ = try await collect(source.enumerateEPUBs(under: .root, since: nil))
        }
        #expect(try await collect(source.enumerateEPUBs(under: .root, since: nil)).count > 0)

        await source.setPageSize(1)
        await source.failEnumeration(afterPages: 1)
        await #expect(throws: RemoteSourceError.notFound) {
            _ = try await collect(source.enumerateEPUBs(under: .root, since: nil))
        }

        await source.expireAuth()
        await #expect(throws: RemoteSourceError.needsRelink) {
            _ = try await source.listFolders(in: nil)
        }
        _ = try await source.link()
        #expect(try await source.listFolders(in: nil).map(\.name) == ["Books", "Other"])
        #expect(await source.enumerationCount == 3)
    }

    @Test("Ranged reads and downloads return the file's bytes")
    func reading() async throws {
        let source = FakeRemoteSource()
        let file = await source.putFile("/Book.epub", data: Data("0123456789".utf8))
        let reader = try #require(source.byteRangeReader(for: file))

        #expect(try await reader.length() == 10)
        #expect(try await reader.read(2..<5) == Data("234".utf8))
        #expect(try await reader.read(8..<20) == Data("89".utf8))
        #expect(await source.rangeReadCount == 2)

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await source.download(file, to: destination) { _ in }
        #expect(try Data(contentsOf: destination) == Data("0123456789".utf8))
    }
}
