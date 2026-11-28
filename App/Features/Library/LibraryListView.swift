import BookStorage
import Core
import Persistence
import SwiftUI

/// The library's list: small cover, title, author, publication year, reading progress, and download state.
/// See docs/UI_SPEC.md#library.
struct LibraryListView: View {
    let books: [Book]
    let downloadProgress: [Book.ID: Double]
    let authorFormat: AuthorDisplayFormat
    let files: BookFileStore?

    var body: some View {
        List(books) { book in
            LibraryListRow(
                book: book,
                status: book.fileStatus(downloadProgress: downloadProgress[book.id]),
                authorFormat: authorFormat,
                files: files
            )
        }
        .listStyle(.plain)
    }
}

private struct LibraryListRow: View {
    let book: Book
    let status: BookFileStatus
    let authorFormat: AuthorDisplayFormat
    let files: BookFileStore?
    @ScaledMetric(relativeTo: .body) private var coverWidth = 44

    /// "1971 · 42%", leaving out what the book doesn't have.
    private var details: String? {
        let parts = [book.publicationYear.map { String($0) }, book.readingPercent.map { "\($0)%" }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        let accessibility = BookAccessibility(book: book, status: status, authorFormat: authorFormat)
        HStack(spacing: 12) {
            BookCover(book: book, authorFormat: authorFormat, files: files)
                .frame(width: coverWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(AuthorNameFormatter.string(for: book.authorName, in: authorFormat))
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                if let details {
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BookFileStatusGlyph(status: status)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityIdentifier("library-book")
    }
}
