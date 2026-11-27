import Foundation

/// What the library needs from an EPUB's package document. See docs/EPUB_METADATA.md.
/// Missing values are nil; `Book.init` swaps in the placeholders ("Unknown Title", "Unknown Author").
public struct EPUBMetadata: Equatable, Sendable {
    public var version: String?
    public var title: String?
    /// Authors in document order. The first one is the primary author used for sorting.
    public var authors: [EPUBAuthor] = []
    /// ISO-8601 date, as precise as the book gives it: "1998", "1998-07", or "1998-07-14".
    public var publicationDate: String?
    /// `yyyymmdd`, with a missing month or day as 00. See docs/DATA_MODEL.md.
    public var publicationDateSort: Int?
    public var seriesName: String?
    public var seriesPosition: Double?
    public var language: String?
    public var publisher: String?
    public var description: String?
    public var identifier: String?
    /// Path of the cover image inside the archive, if one was found and could be decoded.
    public var coverPath: String?
    /// The cover downscaled to at most 600 px on the long edge, as JPEG.
    public var coverThumbnail: Data?

    public init() {}

    /// All authors joined with " & ", or nil when there are none.
    public var authorDisplayName: String? {
        authors.isEmpty ? nil : authors.map(\.name).joined(separator: " & ")
    }
}

public struct EPUBAuthor: Equatable, Sendable {
    public var name: String
    /// The sortable form the book supplies (`file-as`), such as "Le Guin, Ursula K.".
    public var fileAs: String?

    public init(name: String, fileAs: String? = nil) {
        self.name = name
        self.fileAs = fileAs
    }
}

/// Why a book couldn't be read. Sync records the book with placeholders and keeps this as its parse error.
public enum EPUBMetadataError: Error, Equatable, Sendable {
    /// Not a ZIP archive, or a damaged one.
    case unreadableArchive
    case tooManyEntries
    /// The entry is missing from the archive.
    case missingEntry(String)
    /// The entry is bigger than the limits allow, or inflates far more than its compressed size suggests.
    case entryTooLarge(String)
    /// The entry isn't well-formed XML, nests too deeply, or declares entities.
    case malformedXML(String)
    /// `META-INF/container.xml` names no package document.
    case missingPackageDocument
}

/// Limits that keep a hostile EPUB from exhausting memory or time. See docs/SECURITY_AND_APP_STORE.md.
public struct EPUBLimits: Sendable {
    public var maxEntryCount = 10_000
    /// Largest single entry read (container, package document, cover page, or cover image).
    public var maxEntryBytes = 10 * 1024 * 1024
    /// Total uncompressed bytes read from one book.
    public var maxTotalBytes = 20 * 1024 * 1024
    /// Entries over 1 MB may not inflate to more than this many times their compressed size.
    public var maxCompressionRatio = 100
    public var maxXMLDepth = 64
    /// Cover images with more pixels than this are skipped rather than decoded.
    public var maxImagePixels = 50_000_000
    public var thumbnailMaxPixelSize = 600

    public init() {}

    public static let standard = EPUBLimits()
}
