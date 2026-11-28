import BookStorage
import Core
import Foundation
import Persistence
import SwiftUI

/// A collapsible `List` section of books: a first row with the name, the book count, and a chevron that toggles
/// the section, and when expanded a horizontal row of covers. The toggle is a row rather than the section header,
/// because the list dims header text below the contrast the accessibility audit asks for. Shared by the library's
/// collections view (P3.4) and the Collections tab (P4.1). See docs/UI_SPEC.md#collections-tab.
struct CollapsibleBookSection: View {
    let title: String
    let books: [Book]
    @Binding var isExpanded: Bool
    let downloadProgress: [Book.ID: Double]
    let authorFormat: AuthorDisplayFormat
    let files: BookFileStore?

    var body: some View {
        Section {
            SectionHeaderButton(title: title, count: books.count, isExpanded: $isExpanded)
            if isExpanded {
                CoverRow(books: books, downloadProgress: downloadProgress, authorFormat: authorFormat, files: files)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
        }
    }
}

private struct SectionHeaderButton: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    private var countText: String {
        String(AttributedString(localized: "^[\(count) book](inflect: true)").characters)
    }

    var body: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(countText)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(countText)")
        .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("collection-header")
    }
}

/// Covers in a horizontal row, each with its download badge. VoiceOver reads each cover as its book.
private struct CoverRow: View {
    let books: [Book]
    let downloadProgress: [Book.ID: Double]
    let authorFormat: AuthorDisplayFormat
    let files: BookFileStore?
    @ScaledMetric(relativeTo: .body) private var coverWidth = 84

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(books) { book in
                    let status = book.fileStatus(downloadProgress: downloadProgress[book.id])
                    let accessibility = BookAccessibility(book: book, status: status, authorFormat: authorFormat)
                    BookCover(book: book, authorFormat: authorFormat, files: files)
                        .overlay(alignment: .topTrailing) { BookFileStatusBadge(status: status) }
                        .frame(width: coverWidth)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibility.label)
                        .accessibilityValue(accessibility.value)
                        .accessibilityIdentifier("library-book")
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }
}
