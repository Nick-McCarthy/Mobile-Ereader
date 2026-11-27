import Foundation

/// Resolves links inside an EPUB to archive entry paths.
enum ArchivePath {
    /// The directory part of an entry path: "OEBPS/content.opf" → "OEBPS". Top-level entries give "".
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Resolves `href` against `directory`: drops any fragment or query, percent-decodes, and applies "." and "..".
    /// Returns nil for links that leave the archive (absolute URLs, or ".." past the root).
    static func resolve(_ href: String, relativeTo directory: String) -> String? {
        let withoutFragment = href.split(separator: "#", omittingEmptySubsequences: false).first ?? ""
        let withoutQuery = withoutFragment.split(separator: "?", omittingEmptySubsequences: false).first ?? ""
        guard let decoded = String(withoutQuery).removingPercentEncoding, !decoded.isEmpty,
            !decoded.contains("://"), !decoded.hasPrefix("/")
        else { return nil }

        var components = directory.split(separator: "/").map(String.init)
        for component in decoded.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }
}
