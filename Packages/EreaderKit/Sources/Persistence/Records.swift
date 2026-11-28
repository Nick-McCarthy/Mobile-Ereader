import Core
import Foundation
import GRDB

// Record types: one per table in docs/DATA_MODEL.md. Property names match column names.

/// A book in the library (`book` table).
public struct Book: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "book"

    public var id: String

    // Source
    public var sourceKind: SourceKind
    public var sourceId: String?
    public var remoteId: String?
    public var remotePath: String?
    public var remoteVersion: String?
    public var remoteModifiedAt: Date?
    public var fileSize: Int64?

    // Metadata
    public var title: String
    public var titleSort: String
    public var titleIsPlaceholder: Bool
    public var authorRaw: String
    public var authorIsPlaceholder: Bool
    public var authorFileAs: String?
    public var authorStoredFormat: AuthorStoredFormat
    public var authorGiven: String?
    public var authorFamily: String?
    public var publicationDate: String?
    public var publicationDateSort: Int?
    public var language: String?
    public var publisher: String?
    public var description: String?
    public var identifier: String?
    public var coverPath: String?

    // Local state
    public var localFilePath: String?
    public var downloadState: DownloadState
    public var isUserEdited: Bool
    public var userEditedFields: [EditableBookField]
    public var isMissingFromSource: Bool
    public var dateAdded: Date
    public var lastOpenedAt: Date?
    public var progression: Double

    /// A new book. Placeholders are used for a missing title or author, `titleSort` is derived from the title,
    /// and the author's stored format and name parts are detected (see `setAuthor`).
    public init(
        id: String = UUID().uuidString,
        sourceKind: SourceKind,
        title: String?,
        authorRaw: String?,
        authorFileAs: String? = nil,
        authorStoredFormat: AuthorStoredFormat? = nil,
        dateAdded: Date = Date()
    ) {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.id = id
        self.sourceKind = sourceKind
        self.title = cleanTitle.isEmpty ? Placeholders.title : cleanTitle
        self.titleSort = TitleSortKey.make(from: self.title)
        self.titleIsPlaceholder = cleanTitle.isEmpty
        self.authorRaw = Placeholders.author
        self.authorIsPlaceholder = true
        self.authorStoredFormat = .unknown
        self.downloadState = .notDownloaded
        self.isUserEdited = false
        self.userEditedFields = []
        self.isMissingFromSource = false
        self.dateAdded = dateAdded
        self.progression = 0
        setAuthor(raw: authorRaw, fileAs: authorFileAs, storedFormat: authorStoredFormat)
    }

    /// Sets the author and recomputes the sort parts. `storedFormat` nil means detect it from `raw`.
    /// A missing author becomes the placeholder, with no name parts.
    public mutating func setAuthor(raw: String?, fileAs: String?, storedFormat: AuthorStoredFormat? = nil) {
        let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanFileAs = fileAs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        authorFileAs = cleanFileAs.isEmpty ? nil : cleanFileAs
        guard !clean.isEmpty else {
            authorRaw = Placeholders.author
            authorIsPlaceholder = true
            authorStoredFormat = .unknown
            authorGiven = nil
            authorFamily = nil
            return
        }
        let name: AuthorName
        if let storedFormat {
            name = AuthorName(raw: clean, storedFormat: storedFormat, fileAs: authorFileAs)
        } else {
            name = AuthorName(raw: clean, fileAs: authorFileAs)
        }
        authorRaw = clean
        authorIsPlaceholder = false
        authorStoredFormat = name.storedFormat
        authorGiven = name.primary?.given
        authorFamily = name.primary?.family
    }

    /// The author's name parsed with the stored format, ready for `AuthorNameFormatter`.
    public var authorName: AuthorName {
        let format: AuthorStoredFormat = authorIsPlaceholder ? .unknown : authorStoredFormat
        return AuthorName(raw: authorRaw, storedFormat: format, fileAs: authorFileAs)
    }

    /// True for a downloaded book whose source was unlinked. See docs/REMOTE_SOURCES.md#unlinking--detached-books.
    public var isDetached: Bool {
        sourceKind != .local && sourceId == nil
    }
}

/// A user-created collection (`collection` table). Named `BookCollection` to avoid clashing with `Swift.Collection`.
public struct BookCollection: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "collection"

    public var id: String
    public var name: String
    public var sortOrder: Int
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, sortOrder: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// A series (`series` table). Membership and position live in `series_book`.
public struct Series: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "series"

    public var id: String
    public var name: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A book in a series, with its optional number (1.5 works for novellas).
public struct SeriesEntry: Equatable, Sendable {
    public var book: Book
    public var position: Double?
}

/// A bookmark in a book (`bookmark` table).
public struct Bookmark: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bookmark"
    /// Longest snippet the database accepts.
    public static let maxSnippetLength = 160

    public var id: String
    public var bookId: String
    /// A serialised Readium `Locator`.
    public var locatorJSON: String
    public var chapterTitle: String?
    public var progression: Double
    public var textSnippet: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        bookId: String,
        locatorJSON: String,
        chapterTitle: String? = nil,
        progression: Double,
        textSnippet: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookId = bookId
        self.locatorJSON = locatorJSON
        self.chapterTitle = chapterTitle
        self.progression = min(max(progression, 0), 1)
        self.textSnippet = textSnippet.map { String($0.prefix(Self.maxSnippetLength)) }
        self.createdAt = createdAt
    }
}

/// Where the reader was last left in a book (`reading_position` table).
public struct ReadingPosition: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "reading_position"

    public var bookId: String
    /// A serialised Readium `Locator`.
    public var locatorJSON: String
    public var updatedAt: Date

    public init(bookId: String, locatorJSON: String, updatedAt: Date = Date()) {
        self.bookId = bookId
        self.locatorJSON = locatorJSON
        self.updatedAt = updatedAt
    }
}

/// A linked iCloud Drive / Files, Dropbox, or OneDrive folder (`library_source` table).
/// Tokens are never stored here; they live in the Keychain under this row's `id`.
public struct LibrarySource: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "library_source"

    public var id: String
    /// Never `.local`: local imports have no source row.
    public var kind: SourceKind
    /// Display name or email, shown in Settings.
    public var accountLabel: String?
    /// Provider folder id (Dropbox path or id, Graph item id). Empty means the whole drive.
    public var rootId: String?
    /// Security-scoped bookmark of the iCloud Drive / Files folder.
    public var rootBookmark: Data?
    public var rootDisplayPath: String
    /// Where the next incremental sync starts. Nil means a full listing.
    public var syncCursor: String?
    public var status: SourceStatus
    public var lastSyncedAt: Date?
    /// Short, non-sensitive message for Settings.
    public var lastSyncError: String?

    public init(
        id: String = UUID().uuidString,
        kind: SourceKind,
        accountLabel: String? = nil,
        rootId: String? = nil,
        rootBookmark: Data? = nil,
        rootDisplayPath: String = "/"
    ) {
        self.id = id
        self.kind = kind
        self.accountLabel = accountLabel
        self.rootId = rootId
        self.rootBookmark = rootBookmark
        self.rootDisplayPath = rootDisplayPath
        self.status = .ok
    }
}
