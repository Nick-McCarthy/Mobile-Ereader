import Core
import Foundation
import ReadiumZIPFoundation
import Testing

@testable import EPUBMetadata

@Suite("Remote ZIP reader")
struct RemoteZipReaderTests {
    // MARK: Ranged reads

    @Test("Reads the same metadata as a local parse in at most 5 ranged reads", arguments: [true, false])
    func matchesLocalParse(compressed: Bool) async throws {
        let bytes = try await Self.largeBook(compression: compressed ? .deflate : .none)
        #expect(bytes.count > 500_000, "the book must be much bigger than one fetch block")
        let reader = CountingReader(bytes)

        let remote = try await EPUBMetadataReader.read(remote: reader) { _ in Issue.record("fell back") }
        let local = try await Self.parseLocally(bytes)

        #expect(remote == local)
        #expect(remote.title == "Remote Title")
        #expect(remote.coverPath == "OEBPS/images/cover.png")
        #expect(remote.coverThumbnail != nil)
        let reads = await reader.readCount
        #expect(reads >= 1 && reads <= 5, "made \(reads) reads")
        let fetched = await reader.bytesServed
        #expect(fetched < bytes.count / 2, "fetched \(fetched) of \(bytes.count) bytes")
    }

    @Test("A small book is read in a single request")
    func smallBookOneRead() async throws {
        let url = try await EPUBFixture.book(package: Self.package)
        defer { EPUBFixture.cleanUp(url) }
        let reader = CountingReader(try Data(contentsOf: url))

        let metadata = try await EPUBMetadataReader.read(remote: reader) { _ in Issue.record("fell back") }
        #expect(metadata.title == "Remote Title")
        #expect(await reader.readCount == 1)
    }

    @Test("Reads a ZIP64 archive")
    func zip64() async throws {
        let bytes = try Self.convertToZIP64(try await Self.largeBook(compression: .deflate))
        let reader = CountingReader(bytes)

        let remote = try await EPUBMetadataReader.read(remote: reader) { _ in Issue.record("fell back") }
        #expect(remote.title == "Remote Title")
        #expect(remote.coverThumbnail != nil)
        #expect(await reader.readCount <= 5)
        #expect(try await Self.parseLocally(bytes) == remote)
    }

    // MARK: Fallback and errors

    @Test("Falls back to a full download when the server ignores ranges")
    func fallbackWhenRangesIgnored() async throws {
        let bytes = try await Self.largeBook(compression: .deflate)
        let reader = CountingReader(bytes, ignoresRanges: true)
        let downloads = Counter()
        var downloadedTo: URL?

        let metadata = try await EPUBMetadataReader.read(remote: reader) { url in
            await downloads.increment()
            downloadedTo = url
            try bytes.write(to: url)
        }
        #expect(metadata.title == "Remote Title")
        #expect(await downloads.value == 1)
        let url = try #require(downloadedTo)
        #expect(!FileManager.default.fileExists(atPath: url.path), "the temporary copy is deleted")
    }

    @Test("Falls back when the remote bytes aren't a readable ZIP, then reports the local error")
    func fallbackWhenUnreadable() async throws {
        let garbage = Data(repeating: 0x41, count: 4096)
        let downloads = Counter()
        await #expect(throws: EPUBMetadataError.unreadableArchive) {
            _ = try await EPUBMetadataReader.read(remote: CountingReader(garbage)) { url in
                await downloads.increment()
                try garbage.write(to: url)
            }
        }
        #expect(await downloads.value == 1)
    }

    @Test("Reader errors are rethrown without falling back", arguments: [0, 1, 2])
    func readerErrorsPassThrough(failingRead: Int) async throws {
        let bytes = try await Self.largeBook(compression: .deflate)
        let reader = CountingReader(bytes, failOnRead: failingRead)
        await #expect(throws: TestNetworkError.self) {
            _ = try await EPUBMetadataReader.read(remote: reader) { _ in Issue.record("fell back") }
        }
    }

    @Test("Limits still apply to remote archives")
    func limitsApply() async throws {
        let bytes = try await Self.largeBook(compression: .deflate)
        var limits = EPUBLimits.standard
        limits.maxEntryCount = 2
        await #expect(throws: EPUBMetadataError.tooManyEntries) {
            _ = try await EPUBMetadataReader.read(remote: CountingReader(bytes), limits: limits) { _ in
                Issue.record("fell back")
            }
        }
    }

    // MARK: Hostile archives

    @Test("A lying compressed size for a required entry is refused without a large fetch")
    func lyingCompressedSizeRequiredEntry() async throws {
        let bytes = try Self.setCompressedSize(
            in: try await Self.largeBook(compression: .deflate),
            entry: "META-INF/container.xml",
            to: 0x7FFF_FFFF
        )
        let reader = CountingReader(bytes)
        await #expect(throws: EPUBMetadataError.entryTooLarge("META-INF/container.xml")) {
            _ = try await EPUBMetadataReader.read(remote: reader) { _ in Issue.record("fell back") }
        }
        #expect(await reader.largestRequest <= RemoteZipReader.minimumFetch)
        await #expect(throws: EPUBMetadataError.entryTooLarge("META-INF/container.xml")) {
            _ = try await Self.parseLocally(bytes)
        }
    }

    @Test("A lying compressed size for the cover skips the cover without a large fetch")
    func lyingCompressedSizeCover() async throws {
        let bytes = try Self.setCompressedSize(
            in: try await Self.largeBook(compression: .deflate),
            entry: "OEBPS/images/cover.png",
            to: 0x7FFF_FFFF
        )
        let reader = CountingReader(bytes)
        let metadata = try await EPUBMetadataReader.read(remote: reader) { _ in Issue.record("fell back") }
        #expect(metadata.title == "Remote Title")
        #expect(metadata.coverThumbnail == nil)
        #expect(await reader.largestRequest <= RemoteZipReader.minimumFetch)
    }

    @Test("Fetch hints are capped and range arithmetic can't overflow")
    func hintsAreCapped() async throws {
        let length: Int64 = 1 << 40
        let reader = SyntheticReader(length: length)
        let cache = RangeCache(reader: reader)

        await cache.setFetchHint(.max)
        _ = try await cache.bytes(at: 0, count: 1)
        #expect(await reader.largestRequest == RemoteZipReader.maximumFetch)

        let tail = try await cache.bytes(at: length - 10, count: .max)
        #expect(tail.count == 10)
        let beyond = try await cache.bytes(at: .max, count: .max)
        #expect(beyond.isEmpty)
    }

    @Test("A negative reported length falls back to a full download")
    func negativeLengthFallsBack() async throws {
        let bytes = try await Self.largeBook(compression: .deflate)
        let downloads = Counter()
        let metadata = try await EPUBMetadataReader.read(remote: SyntheticReader(length: -1)) { url in
            await downloads.increment()
            try bytes.write(to: url)
        }
        #expect(metadata.title == "Remote Title")
        #expect(await downloads.value == 1)
    }

    // MARK: Fixtures

    static let package = EPUBFixture.package(
        metadata: """
            <dc:title>Remote Title</dc:title>
            <dc:creator>Remote Author</dc:creator>
            <dc:date>2001-02-03</dc:date>
            """,
        manifest: #"<item id="c" href="images/cover.png" media-type="image/png" properties="cover-image"/>"#
    )

    /// A book with ~300 KB of incompressible text either side of the cover, so the container, package
    /// document, cover, and central directory are all in different parts of the file.
    static func largeBook(compression: CompressionMethod) async throws -> Data {
        let url = try await EPUBFixture.book(
            package: package,
            extra: [
                ("OEBPS/chapter1.xhtml", noise(count: 300_000, seed: 1)),
                ("OEBPS/images/cover.png", try EPUBFixture.png(width: 800, height: 1200)),
                ("OEBPS/chapter2.xhtml", noise(count: 300_000, seed: 2)),
            ],
            compression: compression
        )
        defer { EPUBFixture.cleanUp(url) }
        return try Data(contentsOf: url)
    }

    static func parseLocally(_ bytes: Data) async throws -> EPUBMetadata {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")
        try bytes.write(to: url)
        return try await EPUBMetadataReader.read(fileAt: url)
    }

    /// Rewrites the compressed-size field of `entry`'s central-directory record.
    static func setCompressedSize(in zip: Data, entry name: String, to value: UInt32) throws -> Data {
        var bytes = [UInt8](zip)
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let nameBytes = Array(name.utf8)
        var index = 0
        while index + 46 + nameBytes.count <= bytes.count {
            let nameLength = Int(bytes[index + 28]) | Int(bytes[index + 29]) << 8
            if Array(bytes[index..<index + 4]) == signature, nameLength == nameBytes.count,
                Array(bytes[index + 46..<index + 46 + nameLength]) == nameBytes
            {
                for byte in 0..<4 { bytes[index + 20 + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte))) }
                return Data(bytes)
            }
            index += 1
        }
        throw EPUBFixture.FixtureError()
    }

    /// Deterministic bytes that deflate can't shrink.
    static func noise(count: Int, seed: UInt64) -> Data {
        var state = seed
        var data = Data(capacity: count)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            data.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return data
    }

    /// Rewrites a comment-less ZIP's end records as ZIP64: a ZIP64 record and locator carry the real
    /// values, and the classic record holds the 0xFFFF / 0xFFFFFFFF markers.
    static func convertToZIP64(_ zip: Data) throws -> Data {
        let bytes = [UInt8](zip)
        let eocd = bytes.count - 22
        guard eocd > 0, bytes[eocd..<eocd + 4] == [0x50, 0x4B, 0x05, 0x06] else { throw EPUBFixture.FixtureError() }
        func value(at offset: Int, size: Int) -> UInt64 {
            (0..<size).reduce(0) { $0 | UInt64(bytes[eocd + offset + $1]) << (8 * UInt64($1)) }
        }
        let entries = value(at: 10, size: 2)
        let directorySize = value(at: 12, size: 4)
        let directoryOffset = value(at: 16, size: 4)

        var out = Array(bytes[..<eocd])
        func append(_ value: UInt64, size: Int) {
            for index in 0..<size { out.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(index)))) }
        }
        let recordOffset = UInt64(out.count)
        append(0x0606_4B50, size: 4)  // ZIP64 end of central directory record
        append(44, size: 8)  // size of the rest of the record
        append(45, size: 2)  // version made by
        append(45, size: 2)  // version needed: 4.5
        append(0, size: 4)
        append(0, size: 4)
        append(entries, size: 8)
        append(entries, size: 8)
        append(directorySize, size: 8)
        append(directoryOffset, size: 8)
        append(0x0706_4B50, size: 4)  // ZIP64 locator
        append(0, size: 4)
        append(recordOffset, size: 8)
        append(1, size: 4)
        append(0x0605_4B50, size: 4)  // classic end of central directory record
        append(0, size: 2)
        append(0, size: 2)
        append(0xFFFF, size: 2)
        append(0xFFFF, size: 2)
        append(0xFFFF_FFFF, size: 4)
        append(0xFFFF_FFFF, size: 4)
        append(0, size: 2)
        return Data(out)
    }
}

struct TestNetworkError: Error {}

/// Serves `bytes` through ranged reads, counting requests. Can ignore ranges, like a server that
/// answers `200` with the whole file, or fail one request.
actor CountingReader: ByteRangeReading {
    private let bytes: Data
    private let ignoresRanges: Bool
    private let failOnRead: Int?
    private(set) var readCount = 0
    private(set) var bytesServed = 0
    private(set) var largestRequest: Int64 = 0

    init(_ bytes: Data, ignoresRanges: Bool = false, failOnRead: Int? = nil) {
        self.bytes = bytes
        self.ignoresRanges = ignoresRanges
        self.failOnRead = failOnRead
    }

    func length() -> Int64 {
        Int64(bytes.count)
    }

    func read(_ range: Range<Int64>) throws -> Data {
        defer { readCount += 1 }
        largestRequest = max(largestRequest, range.upperBound - range.lowerBound)
        if readCount == failOnRead { throw TestNetworkError() }
        if ignoresRanges { return bytes }
        let lower = Int(max(range.lowerBound, 0))
        let upper = Int(min(range.upperBound, Int64(bytes.count)))
        guard lower < upper else { return Data() }
        bytesServed += upper - lower
        return bytes.subdata(in: lower..<upper)
    }
}

/// A file of zeros of any reported `length` (even a nonsensical one), recording the largest request.
actor SyntheticReader: ByteRangeReading {
    private let reportedLength: Int64
    private(set) var largestRequest: Int64 = 0

    init(length: Int64) {
        reportedLength = length
    }

    func length() -> Int64 {
        reportedLength
    }

    func read(_ range: Range<Int64>) -> Data {
        largestRequest = max(largestRequest, range.upperBound - range.lowerBound)
        return Data(count: Int(range.upperBound - range.lowerBound))
    }
}

actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
