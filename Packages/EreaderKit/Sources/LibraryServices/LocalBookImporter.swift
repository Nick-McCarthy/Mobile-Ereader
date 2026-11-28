import BookStorage
import Core
import EPUBMetadata
import Foundation
import Persistence

/// Why an import failed. Shown to the user in an alert.
public enum BookImportError: Error, Equatable, Sendable {
    /// The file isn't an EPUB (not a ZIP, or no package document).
    case notAnEPUB
}

/// Imports EPUBs the user picks in Files or opens with "Open in…" (action plan P1.5).
///
/// The file is copied into `Books/local/`, its metadata and cover are read from the copy, and a `local`
/// book is saved as downloaded. Nothing is left behind if any step fails.
public struct LocalBookImporter: Sendable {
    let books: any BookRepository
    let files: BookFileStore
    let limits: EPUBLimits

    public init(books: any BookRepository, files: BookFileStore, limits: EPUBLimits = .standard) {
        self.books = books
        self.files = files
        self.limits = limits
    }

    /// Imports the EPUB at `source`, which may be a security-scoped URL from the document picker.
    @discardableResult
    public func importBook(from source: URL, bookId: String = UUID().uuidString) async throws -> Book {
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing { source.stopAccessingSecurityScopedResource() }
        }

        let bookPath = try files.copyLocalBook(from: source, bookId: bookId)
        var coverPath: String?
        do {
            let metadata = try await readMetadata(at: files.url(forBookPath: bookPath))
            if let thumbnail = metadata.coverThumbnail {
                coverPath = try files.saveCover(thumbnail, bookId: bookId)
            }
            var book = Self.makeBook(id: bookId, metadata: metadata)
            book.localFilePath = bookPath
            book.coverPath = coverPath
            book.downloadState = .downloaded
            book.fileSize = Self.fileSize(of: files.url(forBookPath: bookPath))
            try await books.save(book)
            return book
        } catch {
            try? files.removeBook(atPath: bookPath)
            if let coverPath { try? files.removeCover(atPath: coverPath) }
            throw error
        }
    }

    /// Reads metadata, rejecting files that aren't EPUBs. Other parse problems (a damaged package
    /// document, an oversized entry) still import the book, with placeholders.
    private func readMetadata(at url: URL) async throws -> EPUBMetadata {
        do {
            return try await EPUBMetadataReader.read(fileAt: url, limits: limits)
        } catch EPUBMetadataError.unreadableArchive, EPUBMetadataError.missingPackageDocument,
            EPUBMetadataError.missingEntry
        {
            // No container.xml or package document (the only entries the reader requires).
            throw BookImportError.notAnEPUB
        } catch is EPUBMetadataError {
            return EPUBMetadata()
        }
    }

    /// A `Book` from parsed metadata. Placeholders and the author's name parts are filled in by `Book.init`.
    static func makeBook(id: String, metadata: EPUBMetadata) -> Book {
        // file-as describes one person, so it only helps when there is exactly one author.
        let fileAs = metadata.authors.count == 1 ? metadata.authors.first?.fileAs : nil
        var book = Book(
            id: id,
            sourceKind: .local,
            title: metadata.title,
            authorRaw: metadata.authorDisplayName,
            authorFileAs: fileAs
        )
        book.publicationDate = metadata.publicationDate
        book.publicationDateSort = metadata.publicationDateSort
        book.language = metadata.language
        book.publisher = metadata.publisher
        book.description = metadata.description
        book.identifier = metadata.identifier
        return book
    }

    private static func fileSize(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}
