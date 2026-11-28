import Core
import Persistence
import SwiftUI

extension BookFileStatus {
    /// Read by VoiceOver as part of the cell's or row's value.
    var accessibilityText: String {
        switch self {
        case .downloaded: String(localized: "Downloaded")
        case .notDownloaded: String(localized: "Not downloaded")
        case .downloading(let progress?):
            String(localized: "Downloading, \(progress.formatted(.percent.precision(.fractionLength(0))))")
        case .downloading(nil): String(localized: "Downloading")
        case .failed: String(localized: "Download failed")
        case .missingFromSource: String(localized: "Missing from source")
        }
    }
}

/// VoiceOver's label and value for a book: "Title, Author" and "Not downloaded, 42% read".
struct BookAccessibility {
    let book: Book
    let status: BookFileStatus
    let authorFormat: AuthorDisplayFormat

    var label: String {
        "\(book.title), \(AuthorNameFormatter.string(for: book.authorName, in: authorFormat))"
    }

    var value: String {
        var parts = [status.accessibilityText]
        if let percent = book.readingPercent {
            parts.append(String(localized: "\(percent)% read"))
        }
        if let year = book.publicationYear {
            parts.append(String(localized: "Published \(String(year))"))
        }
        return parts.joined(separator: ", ")
    }

    /// What a tap does.
    var hint: String {
        switch status {
        case .downloaded: String(localized: "Opens the book.")
        case .downloading: String(localized: "Cancels the download.")
        case .notDownloaded, .failed, .missingFromSource: String(localized: "Downloads and opens the book.")
        }
    }
}

/// The download state as a small glyph: nothing for a downloaded book, a cloud when it isn't downloaded, a ring
/// while it downloads, and a warning when it failed or is missing from its folder. Decorative: the cell's or
/// row's accessibility value says the same in words.
struct BookFileStatusGlyph: View {
    let status: BookFileStatus
    @ScaledMetric(relativeTo: .footnote) private var size = 18

    var body: some View {
        Group {
            switch status {
            case .downloaded:
                EmptyView()
            case .notDownloaded:
                Image(systemName: "icloud.and.arrow.down")
            case .downloading(let progress):
                DownloadRing(progress: progress).frame(width: size, height: size)
            case .failed:
                Image(systemName: "exclamationmark.icloud")
            case .missingFromSource:
                Image(systemName: "questionmark.folder")
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.accessibleAccent)
        .accessibilityHidden(true)
    }
}

/// A circular progress ring. `ProgressView`'s circular style ignores the value on iOS, so this draws it.
/// With no progress yet it shows a short arc.
struct DownloadRing: View {
    let progress: Double?

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(progress ?? 0.08, 0.04))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.default, value: progress)
    }
}

/// The badge on a grid cover: the status glyph on a small disc in the top corner. Nothing for a downloaded book.
struct BookFileStatusBadge: View {
    let status: BookFileStatus

    var body: some View {
        if status != .downloaded {
            BookFileStatusGlyph(status: status)
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .padding(4)
        }
    }
}
