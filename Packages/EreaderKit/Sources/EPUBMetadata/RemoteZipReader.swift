import Core
import Foundation
import ReadiumZIPFoundation

/// A `DataSource` that reads a ZIP through ranged requests, so `Archive` can parse a remote EPUB without
/// downloading it. See docs/EPUB_METADATA.md#reading-metadata-without-downloading-the-book.
///
/// Requests are few and large: opening fetches the last 64 KB (the end-of-central-directory record and,
/// in most books, the whole central directory), and `EPUBArchive` hints each entry's size before reading
/// it, so an entry usually costs one request. Fetched blocks are cached and reused.
struct RemoteZipReader: DataSource {
    static let minimumFetch: Int64 = 64 * 1024
    /// Room for a local file header's name and extra field, which the central directory doesn't size.
    static let localHeaderSlack: Int64 = 4 * 1024

    let cache: RangeCache

    init(reader: any ByteRangeReading) {
        cache = RangeCache(reader: reader)
    }

    var isWritable: Bool { false }

    func length() async throws -> UInt64 {
        UInt64(try await cache.length())
    }

    func openRead() async throws -> DataSourceTransaction {
        // Prefetch the tail before ZIPFoundation scans backwards for the end-of-central-directory record.
        try await cache.prefetchTail()
        return Transaction(cache: cache)
    }

    /// Tells the reader that the next uncached read starts an entry of `compressedSize` bytes.
    func expectEntry(compressedSize: UInt64) async {
        let size = Int64(clamping: compressedSize)
        await cache.setFetchHint(size.addingReportingOverflow(Self.localHeaderSlack).partialValue)
    }

    private actor Transaction: DataSourceTransaction {
        let cache: RangeCache
        private var offset: Int64 = 0

        init(cache: RangeCache) {
            self.cache = cache
        }

        func position() -> UInt64 {
            UInt64(offset)
        }

        func seek(to position: UInt64) {
            offset = Int64(clamping: position)
        }

        func read(length: Int) async throws -> Data {
            let data = try await cache.bytes(at: offset, count: Int64(length))
            offset += Int64(data.count)
            return data
        }
    }
}

/// The fetched blocks of one remote file. Remembers the first error the reader threw, because
/// `Archive` reports every failure as its own error.
actor RangeCache {
    /// Cached bytes are capped so a hostile archive can't make the reader hold more than this.
    static let maxCachedBytes = 32 * 1024 * 1024

    private struct Block {
        let start: Int64
        let data: Data
        var end: Int64 { start + Int64(data.count) }
    }

    private let reader: any ByteRangeReading
    private var cachedLength: Int64?
    private var blocks: [Block] = []
    private var fetchHint: Int64 = 0
    private(set) var readerError: (any Error)?

    init(reader: any ByteRangeReading) {
        self.reader = reader
    }

    func length() async throws -> Int64 {
        if let cachedLength { return cachedLength }
        let length = try await recording { try await reader.length() }
        cachedLength = length
        return length
    }

    func setFetchHint(_ bytes: Int64) {
        fetchHint = bytes
    }

    func prefetchTail() async throws {
        let length = try await length()
        let start = max(length - RemoteZipReader.minimumFetch, 0)
        guard length > 0, !isCached(start..<length) else { return }
        try await fetch(start..<length)
    }

    /// Up to `count` bytes from `offset`; fewer only at the end of the file.
    func bytes(at offset: Int64, count: Int64) async throws -> Data {
        let length = try await length()
        guard offset >= 0, count > 0, offset < length else { return Data() }
        let wanted = offset..<min(offset + count, length)
        if let block = block(covering: wanted) {
            return slice(of: block, wanted)
        }
        let size = max(RemoteZipReader.minimumFetch, wanted.count64, fetchHint)
        fetchHint = 0
        let block = try await fetch(offset..<min(offset + size, length))
        return slice(of: block, wanted)
    }

    @discardableResult
    private func fetch(_ range: Range<Int64>) async throws -> Block {
        let data = try await recording { try await reader.read(range) }
        // More bytes than asked for means the server ignored the range and sent the whole file.
        guard data.count <= range.count64 else { throw recordFailure(ByteRangeError.rangeNotSupported) }
        guard data.count == range.count64 else { throw recordFailure(ByteRangeError.shortRead) }
        let block = Block(start: range.lowerBound, data: data)
        blocks.append(block)
        var total = blocks.reduce(0) { $0 + $1.data.count }
        while total > Self.maxCachedBytes, blocks.count > 1 {
            total -= blocks.removeFirst().data.count
        }
        return block
    }

    private func isCached(_ range: Range<Int64>) -> Bool {
        block(covering: range) != nil
    }

    private func block(covering range: Range<Int64>) -> Block? {
        blocks.last { $0.start <= range.lowerBound && range.upperBound <= $0.end }
    }

    private func slice(of block: Block, _ range: Range<Int64>) -> Data {
        let lower = Int(range.lowerBound - block.start)
        let upper = Int(range.upperBound - block.start)
        return block.data.subdata(in: lower..<upper)
    }

    private func recording<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw recordFailure(error)
        }
    }

    private func recordFailure(_ error: any Error) -> any Error {
        if readerError == nil { readerError = error }
        return error
    }
}

extension Range where Bound == Int64 {
    fileprivate var count64: Int64 { upperBound - lowerBound }
}
