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

    /// A new book. Placeholders are used for a missing title or author, and `titleSort` is derived from the title.
    public init(
        id: String = UUID().uuidString,
        sourceKind: SourceKind,
        title: String?,
        authorRaw: String?,
        authorStoredFormat: AuthorStoredFormat = .unknown,
        dateAdded: Date = Date()
    ) {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanAuthor = authorRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.id = id
        self.sourceKind = sourceKind
        self.title = cleanTitle.isEmpty ? Placeholders.title : cleanTitle
        self.titleSort = TitleSortKey.make(from: self.title)
        self.titleIsPlaceholder = cleanTitle.isEmpty
        self.authorRaw = cleanAuthor.isEmpty ? Placeholders.author : cleanAuthor
        self.authorIsPlaceholder = cleanAuthor.isEmpty
        self.authorStoredFormat = authorStoredFormat
        self.downloadState = .notDownloaded
        self.isUserEdited = false
        self.userEditedFields = []
        self.isMissingFromSource = false
        self.dateAdded = dateAdded
        self.progression = 0
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
