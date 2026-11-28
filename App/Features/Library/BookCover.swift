import BookStorage
import Core
import Persistence
import SwiftUI

/// A book's cover at 2:3, filling the width it is given: the extracted cover, or a generated placeholder with
/// the title and author on a tint picked from the title. Decorative, because the cell or row around it already
/// names the book, so VoiceOver skips it. See docs/UI_SPEC.md#library and docs/EPUB_METADATA.md.
struct BookCover: View {
    let book: Book
    let authorFormat: AuthorDisplayFormat
    let files: BookFileStore?
    @State private var loaded: UIImage?

    private var coverURL: URL? {
        guard let path = book.coverPath, let files else { return nil }
        return files.url(forCoverPath: path)
    }

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image = loaded ?? coverURL.flatMap(CoverImageCache.shared.cachedImage(at:)) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    PlaceholderCoverView(
                        title: book.title,
                        author: AuthorNameFormatter.string(for: book.authorName, in: authorFormat)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
            .task(id: coverURL) {
                loaded = nil
                guard let coverURL else { return }
                loaded = await CoverImageCache.shared.image(at: coverURL)
            }
    }
}

/// Title and author on a dark tint, sized to the cover so it reads the same in a grid cell and a list row.
/// Drawn in a `Canvas`, so the text is part of the picture rather than text elements: the cover is decorative,
/// and its type is sized to the cover rather than to Dynamic Type, which the accessibility audit would flag.
private struct PlaceholderCoverView: View {
    let title: String
    let author: String

    /// Dark enough for white text in light and dark mode.
    private static let tints: [Color] = [
        Color(red: 0.18, green: 0.32, blue: 0.46),
        Color(red: 0.42, green: 0.20, blue: 0.24),
        Color(red: 0.20, green: 0.38, blue: 0.30),
        Color(red: 0.36, green: 0.26, blue: 0.46),
        Color(red: 0.46, green: 0.32, blue: 0.16),
        Color(red: 0.16, green: 0.36, blue: 0.40),
        Color(red: 0.30, green: 0.30, blue: 0.34),
        Color(red: 0.44, green: 0.22, blue: 0.38),
    ]

    var body: some View {
        let tint = Self.tints[PlaceholderCover.tintIndex(for: title, count: Self.tints.count)]
        Canvas { context, size in
            let padding = size.width * 0.08
            let inner = CGSize(width: size.width - padding * 2, height: size.height - padding * 2)
            guard inner.width > 0, inner.height > 0 else { return }

            var authorHeight: CGFloat = 0
            if size.width >= 60 {
                var author = context.resolve(Text(self.author).font(.system(size: size.width * 0.08)))
                author.shading = .color(.white)
                let measured = author.measure(in: CGSize(width: inner.width, height: inner.height * 0.3))
                authorHeight = measured.height + padding
                let origin = CGPoint(x: (size.width - measured.width) / 2, y: size.height - padding - measured.height)
                context.draw(author, in: CGRect(origin: origin, size: measured))
            }

            let titleFont = Font.system(size: max(size.width * 0.12, 5), weight: .semibold, design: .serif)
            var title = context.resolve(Text(self.title).font(titleFont))
            title.shading = .color(.white)
            let room = CGSize(width: inner.width, height: inner.height - authorHeight)
            let measured = title.measure(in: room)
            let origin = CGPoint(x: (size.width - measured.width) / 2, y: padding + (room.height - measured.height) / 2)
            context.draw(title, in: CGRect(origin: origin, size: measured))
        }
        .background(tint.gradient)
    }
}
