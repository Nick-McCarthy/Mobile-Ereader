import Foundation

/// Random access to a file's bytes without downloading all of it, such as HTTP `Range` requests.
/// Remote sources provide one per file; `RemoteZipReader` (P2.3) reads EPUB metadata through it.
/// See docs/EPUB_METADATA.md#reading-metadata-without-downloading-the-book.
public protocol ByteRangeReading: Sendable {
    /// Total size of the file in bytes.
    func length() async throws -> Int64
    /// The bytes in `range`. May return fewer bytes only at the end of the file.
    func read(_ range: Range<Int64>) async throws -> Data
}

/// Failures of a `ByteRangeReading` that mean ranged reads can't be used for this file.
public enum ByteRangeError: Error, Equatable {
    /// The server ignored the range and sent the whole file.
    case rangeNotSupported
    /// Fewer bytes than requested arrived before the end of the file.
    case shortRead
    /// The reported file length was negative.
    case invalidLength
}
