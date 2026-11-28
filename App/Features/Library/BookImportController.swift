import Foundation
import LibraryServices
import Observation

/// Runs imports from the Files picker and "Open in…", and holds the message for a failed import.
@MainActor
@Observable
final class BookImportController {
    private let importer: LocalBookImporter
    private(set) var isImporting = false
    /// Set when an import fails; the Library shows it in an alert and clears it.
    var errorMessage: String?

    init(importer: LocalBookImporter) {
        self.importer = importer
    }

    /// Imports each file in turn. Files the system copied into `Documents/Inbox` for "Open in…" are deleted
    /// afterwards: the app keeps its own copy in `Books/local`.
    func importBooks(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        var failed: [String] = []
        for url in urls {
            do {
                try await importer.importBook(from: url)
            } catch {
                failed.append(url.lastPathComponent)
            }
            if Self.isInboxFile(url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if !failed.isEmpty {
            errorMessage = String(
                localized: "Couldn't import \(failed.formatted(.list(type: .and))). Make sure each file is an EPUB."
            )
        }
    }

    private static func isInboxFile(_ url: URL) -> Bool {
        url.isFileURL && url.path(percentEncoded: false).contains("/Documents/Inbox/")
    }
}
