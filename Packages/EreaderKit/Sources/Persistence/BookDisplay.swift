import Core

/// What the library shows about a book's file: the badge on a grid cover and the status in a list row
/// (action plan P3.1, docs/UI_SPEC.md#library).
public enum BookFileStatus: Equatable, Sendable {
    case downloaded
    case notDownloaded
    /// `progress` is 0…1, or nil before the download reports any.
    case downloading(progress: Double?)
    case failed
    /// The file is no longer in the linked folder; a downloaded copy can still be read.
    case missingFromSource
}

extension Book {
    /// The file status, given the progress of a running download (from `DownloadManager.observeProgress()`).
    /// A running download wins over the stored state, which lags behind it.
    public func fileStatus(downloadProgress: Double?) -> BookFileStatus {
        if let downloadProgress { return .downloading(progress: min(max(downloadProgress, 0), 1)) }
        switch downloadState {
        case .downloading: return .downloading(progress: nil)
        case .failed: return .failed
        case .downloaded: return .downloaded
        case .notDownloaded: return isMissingFromSource ? .missingFromSource : .notDownloaded
        }
    }

    /// Reading progress as a whole percentage, or nil for a book that hasn't been started.
    /// A started book shows at least 1 %, and only a finished one shows 100 %.
    public var readingPercent: Int? {
        guard progression > 0 else { return nil }
        if progression >= 1 { return 100 }
        return min(max(Int((progression * 100).rounded()), 1), 99)
    }

    /// The year of publication, or nil when the EPUB has no date.
    public var publicationYear: Int? {
        publicationDateSort.map { $0 / 10_000 }.flatMap { $0 > 0 ? $0 : nil }
    }
}
