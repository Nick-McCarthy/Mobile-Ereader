import BookStorage
import Core
import Persistence
import SwiftUI

/// The library's grid: covers in adaptive columns of about 110 pt, title and author
/// under each (wrapped, not truncated: the audit flags a line limit as clipping at large Dynamic Type sizes), and
/// a download badge on the cover. See docs/UI_SPEC.md#library.
struct LibraryGridView: View {
    let books: [Book]
    let downloadProgress: [Book.ID: Double]
    let authorFormat: AuthorDisplayFormat
    let files: BookFileStore?
    /// Not scaled with Dynamic Type: when larger type changes the column count, cells move to other rows, and the
    /// accessibility audit reports their text as not supporting Dynamic Type. Captions wrap instead, and the list
    /// view suits the largest sizes better.
    private let columnWidth: CGFloat = 110

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), spacing: 16, alignment: .top)], spacing: 20) {
                ForEach(books) { book in
                    LibraryGridCell(
                        book: book,
                        status: book.fileStatus(downloadProgress: downloadProgress[book.id]),
                        authorFormat: authorFormat,
                        files: files
                    )
                }
            }
            .padding()
        }
    }
}

private struct LibraryGridCell: View {
    let book: Book
    let status: BookFileStatus
    let authorFormat: AuthorDisplayFormat
    let files: BookFileStore?

    var body: some View {
        let accessibility = BookAccessibility(book: book, status: status, authorFormat: authorFormat)
        VStack(alignment: .leading, spacing: 4) {
            BookCover(book: book, authorFormat: authorFormat, files: files)
                .overlay(alignment: .topTrailing) { BookFileStatusBadge(status: status) }
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            // Full height, so a grid row never squeezes the text when the type grows.
            Group {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                Text(AuthorNameFormatter.string(for: book.authorName, in: authorFormat))
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityIdentifier("library-book")
    }
}
