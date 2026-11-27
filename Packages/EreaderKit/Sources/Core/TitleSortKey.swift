import Foundation

/// Builds `book.titleSort`: lower-cased, accents removed, and a leading "the", "a", or "an" dropped,
/// so "The Hobbit" sorts under H. See docs/DATA_MODEL.md.
public enum TitleSortKey {
    private static let leadingArticles = ["the ", "a ", "an "]

    public static func make(from title: String) -> String {
        let folded = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for article in leadingArticles where folded.hasPrefix(article) {
            let remainder = folded.dropFirst(article.count).trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty {
                return remainder
            }
        }
        return folded
    }
}
