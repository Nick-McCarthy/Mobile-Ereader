import Foundation
import ReadiumZIPFoundation

/// Read-only access to an EPUB's entries, enforcing `EPUBLimits`. Entries are read into memory, never extracted.
actor EPUBArchive {
    private static let ratioCheckThreshold: UInt64 = 1024 * 1024

    private let archive: Archive
    private let entries: [String: Entry]
    /// Lower-cased paths, for books whose links don't match the archive's capitalisation.
    private let caseInsensitiveEntries: [String: Entry]
    private let limits: EPUBLimits
    /// Set when the archive is read through ranged requests; told each entry's size before it is read.
    private let remote: RemoteZipReader?
    private var bytesRead = 0

    init(fileURL: URL, limits: EPUBLimits) async throws {
        try await self.init(limits: limits, remote: nil) { try await Archive(url: fileURL, accessMode: .read) }
    }

    init(remote: RemoteZipReader, limits: EPUBLimits) async throws {
        try await self.init(limits: limits, remote: remote) { try await Archive(url: nil, dataSource: remote) }
    }

    private init(
        limits: EPUBLimits,
        remote: RemoteZipReader?,
        open: () async throws -> Archive
    ) async throws {
        let archive: Archive
        let entries: [Entry]
        do {
            archive = try await open()
            entries = try await archive.entries()
        } catch {
            throw EPUBMetadataError.unreadableArchive
        }
        guard entries.count <= limits.maxEntryCount else { throw EPUBMetadataError.tooManyEntries }
        self.archive = archive
        self.limits = limits
        self.remote = remote
        self.entries = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        self.caseInsensitiveEntries = Dictionary(
            entries.map { ($0.path.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func contains(_ path: String) -> Bool {
        entry(at: path) != nil
    }

    /// The entry's uncompressed bytes. Throws if it is missing or breaks a limit.
    ///
    /// Callers read one entry at a time (`EPUBMetadataReader` awaits each read). `bytesRead` and the remote
    /// reader's fetch hint rely on that: concurrent reads could pass the total limit or swap hints.
    func data(at path: String) async throws -> Data {
        guard let entry = entry(at: path), entry.type == .file else { throw EPUBMetadataError.missingEntry(path) }
        let allowed = max(min(limits.maxEntryBytes, limits.maxTotalBytes - bytesRead), 0)
        let declared = entry.uncompressedSize
        guard declared <= UInt64(allowed) else { throw EPUBMetadataError.entryTooLarge(path) }
        // Deflate never grows data by more than a few bytes per block, so a compressed size far above the
        // uncompressed one is a lie. Checking it bounds what a remote read fetches for this entry.
        guard entry.compressedSize <= Self.maxCompressedSize(forUncompressed: declared) else {
            throw EPUBMetadataError.entryTooLarge(path)
        }
        if declared > Self.ratioCheckThreshold {
            let compressed = max(entry.compressedSize, 1)
            guard declared / compressed <= UInt64(limits.maxCompressionRatio) else {
                throw EPUBMetadataError.entryTooLarge(path)
            }
        }

        // Declared sizes can lie, so the collector also stops once the real output passes the limit.
        let collector = ByteCollector(limit: allowed)
        await remote?.expectEntry(compressedSize: entry.compressedSize)
        do {
            _ = try await archive.extract(entry) { chunk in try await collector.append(chunk) }
        } catch is ByteCollector.LimitExceeded {
            throw EPUBMetadataError.entryTooLarge(path)
        } catch {
            throw EPUBMetadataError.unreadableArchive
        }
        let data = await collector.data
        bytesRead += data.count
        return data
    }

    /// The largest plausible compressed size: stored data is the same size, and deflate adds at most
    /// 5 bytes per 16 KB block plus a small header. The margin is generous.
    static func maxCompressedSize(forUncompressed size: UInt64) -> UInt64 {
        size + size / 100 + 1024
    }

    private func entry(at path: String) -> Entry? {
        entries[path] ?? caseInsensitiveEntries[path.lowercased()]
    }
}

/// Accumulates extracted chunks, refusing to grow past `limit`.
private actor ByteCollector {
    struct LimitExceeded: Error {}

    private(set) var data = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) throws {
        guard data.count + chunk.count <= limit else { throw LimitExceeded() }
        data.append(chunk)
    }
}
