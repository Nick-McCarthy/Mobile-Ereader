import BookStorage
import Core
import CryptoKit
import EPUBMetadata
import Foundation
import Persistence

/// Why an import failed. Shown to the user in an alert.
public enum BookImportError: Error, Equatable, Sendable {
    /// The file isn't an EPUB (not a ZIP, or no package document).
    case notAnEPUB
    /// The library already has this book: the same package identifier or, without one, the same bytes.
    /// Nothing was imported; import again with `.keepBoth` or `.replace(existingId)`.
    case duplicate(existingId: Book.ID, title: String)
}

/// What to do when an imported book is already in the library (finding F-D3).
public enum DuplicateHandling: Equatable, Sendable {
    /// Throw `BookImportError.duplicate`, so the user can choose.
    case ask
    /// Import it as a second book.
    case keepBoth
    /// Update that book in place with the new file and metadata. It keeps its id, so collections, series,
    /// bookmarks, and reading position stay, and so do fields the user edited.
    case replace(Book.ID)
}

/// Imports EPUBs the user picks in Files or opens with "Open in…" (action plan P1.5).
///
/// The file is copied into `Books/local/`, its metadata and cover are read from the copy, and a `local`
/// book is saved as downloaded, with its series if the EPUB names one. Nothing is left behind if any step
/// fails.
public struct LocalBookImporter: Sendable {
    let books: any BookRepository
    let series: any SeriesRepository
    let files: BookFileStore
    let limits: EPUBLimits

    public init(
        books: any BookRepository,
        series: any SeriesRepository,
        files: BookFileStore,
        limits: EPUBLimits = .standard
    ) {
        self.books = books
        self.series = series
        self.files = files
        self.limits = limits
    }

    /// Imports the EPUB at `source`, which may be a security-scoped URL from the document picker.
    @discardableResult
    public func importBook(
        from source: URL,
        bookId: String = UUID().uuidString,
        duplicates: DuplicateHandling = .ask
    ) async throws -> Book {
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing { source.stopAccessingSecurityScopedResource() }
        }

        let bookPath = try files.copyLocalBook(from: source, bookId: bookId)
        let bookURL = files.url(forBookPath: bookPath)
        var coverPath: String?
        let book: Book
        let replaced: Book?
        let metadata: EPUBMetadata
        do {
            metadata = try await readMetadata(at: bookURL)
            let fileSize = Self.fileSize(of: bookURL)
            if duplicates == .ask, let existing = try await duplicate(of: metadata, fileAt: bookURL, size: fileSize) {
                throw BookImportError.duplicate(existingId: existing.id, title: existing.title)
            }
            if let thumbnail = metadata.coverThumbnail {
                coverPath = try files.saveCover(thumbnail, bookId: bookId)
            }
            var imported = Self.makeBook(id: bookId, metadata: metadata)
            imported.localFilePath = bookPath
            imported.coverPath = coverPath
            imported.downloadState = .downloaded
            imported.fileSize = fileSize
            if case .replace(let existingId) = duplicates, let existing = try await books.book(id: existingId) {
                imported = Self.replacing(existing, with: imported)
                replaced = existing
            } else {
                replaced = nil
            }
            try await books.save(imported)
            book = imported
        } catch {
            try? files.removeBook(atPath: bookPath)
            if let coverPath { try? files.removeCover(atPath: coverPath) }
            throw error
        }

        // The book is saved; from here on, failures only lose extras, never the import.
        if let replaced {
            if let old = replaced.localFilePath, old != book.localFilePath { try? files.removeBook(atPath: old) }
            if let old = replaced.coverPath, old != book.coverPath { try? files.removeCover(atPath: old) }
            // A user-chosen cover was kept, so the new file's cover isn't needed.
            if let coverPath, coverPath != book.coverPath { try? files.removeCover(atPath: coverPath) }
        }
        try? await saveSeries(from: metadata, forBook: book.id)
        return book
    }

    /// Puts the book in the EPUB's series (created if new), unless it is already in one: a series the user
    /// chose wins over the file's.
    private func saveSeries(from metadata: EPUBMetadata, forBook bookId: Book.ID) async throws {
        guard let name = metadata.seriesName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            try await series.series(containing: bookId) == nil
        else { return }
        let found = try await series.findOrCreateSeries(named: name)
        try await series.setSeries(found.id, position: metadata.seriesPosition, forBook: bookId)
    }

    /// A local book that is the same as the imported one: the same package identifier or, when the EPUB
    /// has none, the same size and SHA-256.
    private func duplicate(of metadata: EPUBMetadata, fileAt url: URL, size: Int64?) async throws -> Book? {
        let local = try await books.fetchLibrary(LibraryQuery()).filter { $0.sourceKind == .local }
        if let identifier = metadata.identifier, !identifier.isEmpty {
            return local.first { $0.identifier == identifier }
        }
        guard let size else { return nil }
        let sameSize = local.filter { $0.fileSize == size && $0.localFilePath != nil }
        guard !sameSize.isEmpty else { return nil }
        let digest = try Self.sha256(of: url)
        return sameSize.first { candidate in
            guard let path = candidate.localFilePath else { return false }
            return (try? Self.sha256(of: files.url(forBookPath: path))) == digest
        }
    }

    /// The imported book as an update of `existing`: its id and reading state, and any field the user edited.
    static func replacing(_ existing: Book, with imported: Book) -> Book {
        var book = imported
        book.id = existing.id
        book.dateAdded = existing.dateAdded
        book.lastOpenedAt = existing.lastOpenedAt
        book.progression = existing.progression
        book.isUserEdited = existing.isUserEdited
        book.userEditedFields = existing.userEditedFields
        for field in existing.userEditedFields {
            switch field {
            case .title:
                book.title = existing.title
                book.titleSort = existing.titleSort
                book.titleIsPlaceholder = existing.titleIsPlaceholder
            case .author:
                book.authorRaw = existing.authorRaw
                book.authorIsPlaceholder = existing.authorIsPlaceholder
                book.authorFileAs = existing.authorFileAs
                book.authorStoredFormat = existing.authorStoredFormat
                book.authorGiven = existing.authorGiven
                book.authorFamily = existing.authorFamily
            case .publicationDate:
                book.publicationDate = existing.publicationDate
                book.publicationDateSort = existing.publicationDateSort
            case .cover:
                book.coverPath = existing.coverPath
            }
        }
        return book
    }

    private static func sha256(of url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
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
