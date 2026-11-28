import Foundation
import LibraryServices
import Observation

/// Runs imports from the Files picker and "Open in…", holds the message for a failed import, and asks
/// what to do with books the library already has.
@MainActor
@Observable
final class BookImportController {
    /// A picked file that matches a book in the library, waiting for the user to choose.
    struct Duplicate: Identifiable {
        let id = UUID()
        let url: URL
        let existingId: String
        let title: String
    }

    enum DuplicateChoice {
        case replace, keepBoth, skip
    }

    private let importer: LocalBookImporter
    private(set) var isImporting = false
    /// Set when an import fails; the Library shows it in an alert and clears it.
    var errorMessage: String?
    /// Duplicates still to ask about. The Library asks about the first one.
    private(set) var duplicates: [Duplicate] = []

    init(importer: LocalBookImporter) {
        self.importer = importer
    }

    /// Imports each file in turn. Files the system copied into `Documents/Inbox` for "Open in…" are deleted
    /// afterwards: the app keeps its own copy in `Books/local`. A duplicate's file is kept until the user
    /// has chosen.
    func importBooks(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        var failed: [String] = []
        for url in urls {
            do {
                try await importer.importBook(from: url)
            } catch BookImportError.duplicate(let existingId, let title) {
                duplicates.append(Duplicate(url: url, existingId: existingId, title: title))
                continue
            } catch {
                failed.append(url.lastPathComponent)
            }
            Self.removeIfInbox(url)
        }
        report(failed)
    }

    /// Acts on the user's choice for the first waiting duplicate. It leaves the queue at once, so the alert
    /// can move on to the next one.
    func resolveFirstDuplicate(_ choice: DuplicateChoice) {
        guard !duplicates.isEmpty else { return }
        let duplicate = duplicates.removeFirst()
        Task { await resolve(duplicate, choice) }
    }

    private func resolve(_ duplicate: Duplicate, _ choice: DuplicateChoice) async {
        defer { Self.removeIfInbox(duplicate.url) }
        let handling: DuplicateHandling
        switch choice {
        case .skip: return
        case .keepBoth: handling = .keepBoth
        case .replace: handling = .replace(duplicate.existingId)
        }
        isImporting = true
        defer { isImporting = false }
        do {
            try await importer.importBook(from: duplicate.url, duplicates: handling)
        } catch {
            report([duplicate.url.lastPathComponent])
        }
    }

    private func report(_ failed: [String]) {
        guard !failed.isEmpty else { return }
        errorMessage = String(
            localized: "Couldn't import \(failed.formatted(.list(type: .and))). Make sure each file is an EPUB."
        )
    }

    private static func removeIfInbox(_ url: URL) {
        guard url.isFileURL, url.path(percentEncoded: false).contains("/Documents/Inbox/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
