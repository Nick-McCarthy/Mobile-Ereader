import Core
import Foundation

/// Where book files and cover thumbnails live on the device. See docs/ARCHITECTURE.md#file-storage-on-device.
///
/// The database stores paths relative to these roots (`Books/local/<bookId>.epub`, `<bookId>.jpg`), because the
/// app container's absolute path changes between installs and restores.
public struct BookFileStore: Sendable {
    public static let localBooksDirectory = "Books/local"
    public static let remoteBooksDirectory = "Books/remote"

    /// Usually `Application Support`. Book paths are relative to it.
    public let applicationSupport: URL
    /// `Caches/Covers`. Cover paths are relative to it.
    public let coversDirectory: URL

    public init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.coversDirectory = caches.appendingPathComponent("Covers", isDirectory: true)
    }

    /// The app's real Application Support and Caches directories.
    public static func standard() throws -> BookFileStore {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return BookFileStore(applicationSupport: support, caches: caches)
    }

    /// The file for a stored book path such as `Books/local/<bookId>.epub`.
    public func url(forBookPath path: String) -> URL {
        applicationSupport.appendingPathComponent(path, isDirectory: false)
    }

    /// The file for a stored cover path such as `<bookId>.jpg`.
    public func url(forCoverPath path: String) -> URL {
        coversDirectory.appendingPathComponent(path, isDirectory: false)
    }

    /// Copies an imported EPUB to `Books/local/<bookId>.epub` and returns the stored path.
    /// The read is file-coordinated, so it works with files from other apps' providers (iCloud Drive, etc.).
    public func copyLocalBook(from source: URL, bookId: String) throws -> String {
        let path = "\(Self.localBooksDirectory)/\(try Self.safeFileName(bookId)).epub"
        let destination = url(forBookPath: path)
        try FileProtection.createDirectory(at: destination.deletingLastPathComponent())

        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        try FileProtection.apply(to: destination)
        return path
    }

    /// Where a download of the book is written before it is complete: `Books/remote/<bookId>.partial`.
    /// It's on the same volume as the final file, so committing it is a rename.
    public func partialDownloadURL(bookId: String) throws -> URL {
        let directory = url(forBookPath: Self.remoteBooksDirectory)
        try FileProtection.createDirectory(at: directory)
        return directory.appendingPathComponent("\(try Self.safeFileName(bookId)).partial", isDirectory: false)
    }

    /// Moves a finished download to `Books/remote/<bookId>.epub`, replacing any older copy in one step, applies
    /// Data Protection, and excludes it from backups (it can be downloaded again). Returns the stored path.
    public func commitDownload(from partial: URL, bookId: String) throws -> String {
        let path = "\(Self.remoteBooksDirectory)/\(try Self.safeFileName(bookId)).epub"
        let destination = url(forBookPath: path)
        try FileProtection.createDirectory(at: destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        try FileProtection.apply(to: destination)
        try setExcludedFromBackup(true, bookPath: path)
        return path
    }

    /// Includes or excludes a stored book from device backups. Downloads are excluded; a detached book's file
    /// is the only copy, so it is included again (P2.10).
    public func setExcludedFromBackup(_ excluded: Bool, bookPath path: String) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        var fileURL = url(forBookPath: path)
        try fileURL.setResourceValues(values)
    }

    /// The size of a file in bytes, or nil if it can't be read.
    public static func size(of fileURL: URL) -> Int64? {
        (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
    }

    /// Writes a cover thumbnail to `Caches/Covers/<bookId>.jpg` and returns the stored path.
    public func saveCover(_ jpeg: Data, bookId: String) throws -> String {
        let path = "\(try Self.safeFileName(bookId)).jpg"
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        try jpeg.write(to: url(forCoverPath: path), options: .atomic)
        return path
    }

    /// Deletes a stored book file. Missing files are ignored.
    public func removeBook(atPath path: String) throws {
        try Self.removeIfPresent(url(forBookPath: path))
    }

    /// Deletes a stored cover. Missing files are ignored.
    public func removeCover(atPath path: String) throws {
        try Self.removeIfPresent(url(forCoverPath: path))
    }

    /// Book ids become file names, so they must not be able to name another directory.
    static func safeFileName(_ bookId: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !bookId.isEmpty, bookId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return bookId
    }

    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
