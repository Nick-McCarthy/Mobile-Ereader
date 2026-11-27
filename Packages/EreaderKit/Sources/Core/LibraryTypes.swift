/// Whether a book's file is on the device. Stored in `book.downloadState`.
public enum DownloadState: String, CaseIterable, Codable, Sendable {
    case notDownloaded
    case downloading
    case downloaded
    case failed
}

/// How an author's name is written in the EPUB. See docs/EPUB_METADATA.md#author-name-normalisation.
public enum AuthorStoredFormat: String, CaseIterable, Codable, Sendable {
    /// "Ursula K. Le Guin"
    case firstLast
    /// "Le Guin, Ursula K."
    case lastFirst
    /// Organisations and names that can't be split; shown as stored.
    case unknown
}

/// Book fields the user can edit. Sync never overwrites an edited field.
public enum EditableBookField: String, CaseIterable, Codable, Sendable {
    case title
    case author
    case publicationDate
    case cover
}

/// Library sort options. See docs/DATA_MODEL.md#display-rules.
public enum LibrarySortOrder: String, CaseIterable, Codable, Sendable {
    /// Most recently opened first; never-opened books last.
    case recentlyViewed
    /// A to Z, ignoring leading articles; placeholder titles last.
    case title
    /// By family name, then given name; placeholder authors last.
    case author
    /// Oldest first; undated books last.
    case publicationDate
    /// Downloaded books first.
    case downloadState
}
