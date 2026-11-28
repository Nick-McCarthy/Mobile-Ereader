import BookStorage
import CoreGraphics
import Foundation
import ImageIO
import LibraryServices
import Persistence
import ReadiumZIPFoundation
import Testing

@Suite("Local book import")
struct LocalBookImporterTests {
    let root: URL
    let files: BookFileStore
    let repositories: DatabaseRepositories
    let importer: LocalBookImporter

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = BookFileStore(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
        importer = LocalBookImporter(books: repositories.books, series: repositories.series, files: files)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test("Importing a fixture EPUB stores the file, cover, and metadata")
    func importsBook() async throws {
        defer { cleanUp() }
        let package = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:isbn:9780000000001</dc:identifier>
                <dc:title>A Wizard of Earthsea</dc:title>
                <dc:creator id="c1">Ursula K. Le Guin</dc:creator>
                <meta refines="#c1" property="file-as">Le Guin, Ursula K.</meta>
                <dc:date>1968-11-01</dc:date>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
              </manifest>
            </package>
            """
        let source = try await writeEPUB(
            named: "Earthsea.epub",
            package: package,
            extra: [("OEBPS/cover.png", try pngData(width: 400, height: 600))]
        )

        let imported = try await importer.importBook(from: source, bookId: "B1")
        let stored = try #require(try await repositories.books.book(id: "B1"))
        #expect(stored.id == imported.id)
        #expect(stored.sourceKind == .local)
        #expect(stored.title == "A Wizard of Earthsea")
        #expect(stored.authorRaw == "Ursula K. Le Guin")
        #expect(stored.authorFileAs == "Le Guin, Ursula K.")
        #expect(stored.authorStoredFormat == .firstLast)
        #expect(stored.authorFamily == "Le Guin")
        #expect(stored.publicationDate == "1968-11-01")
        #expect(stored.publicationDateSort == 19_681_101)
        #expect(stored.language == "en")
        #expect(stored.identifier == "urn:isbn:9780000000001")
        #expect(stored.downloadState == .downloaded)
        #expect(stored.localFilePath == "Books/local/B1.epub")
        #expect(stored.coverPath == "B1.jpg")
        #expect(stored.fileSize ?? 0 > 0)
        #expect(exists(files.url(forBookPath: "Books/local/B1.epub")))
        #expect(exists(files.url(forCoverPath: "B1.jpg")))
        #expect(exists(source), "the picked file is copied, not moved")
    }

    @Test("A book without metadata gets placeholders and no cover")
    func placeholders() async throws {
        defer { cleanUp() }
        let source = try await writeEPUB(
            named: "Bare.epub",
            package: #"<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata/></package>"#
        )

        let book = try await importer.importBook(from: source)
        #expect(book.titleIsPlaceholder)
        #expect(book.authorIsPlaceholder)
        #expect(book.coverPath == nil)
        #expect(try await repositories.books.book(id: book.id) != nil)
    }

    @Test("A file that isn't an EPUB is refused and leaves nothing behind")
    func notAnEPUB() async throws {
        defer { cleanUp() }
        let source = root.appendingPathComponent("notes.epub")
        try Data("just some text".utf8).write(to: source)

        await #expect(throws: BookImportError.notAnEPUB) {
            _ = try await importer.importBook(from: source, bookId: "B2")
        }
        #expect(try await repositories.books.fetchLibrary(LibraryQuery()).isEmpty)
        #expect(!exists(files.url(forBookPath: "Books/local/B2.epub")))
    }

    // MARK: Series

    @Test("The EPUB's series is saved, reusing a series of the same name")
    func savesSeries() async throws {
        defer { cleanUp() }
        let existing = try await repositories.series.createSeries(named: "earthsea")
        let source = try await writeEPUB(named: "Tombs.epub", package: Self.package(identifier: "tombs", series: 2))

        let book = try await importer.importBook(from: source)
        let membership = try #require(try await repositories.series.series(containing: book.id))
        #expect(membership.series.id == existing.id, "names match ignoring case")
        #expect(membership.position == 2)
    }

    @Test("A replaced book keeps the series the user chose")
    func keepsChosenSeries() async throws {
        defer { cleanUp() }
        let source = try await writeEPUB(named: "Tombs.epub", package: Self.package(identifier: "tombs", series: 2))
        let book = try await importer.importBook(from: source, bookId: "B1")
        let chosen = try await repositories.series.createSeries(named: "Favourites")
        try await repositories.series.setSeries(chosen.id, position: nil, forBook: "B1")

        _ = try await importer.importBook(from: source, duplicates: .replace(book.id))
        #expect(try await repositories.series.series(containing: "B1")?.series.id == chosen.id)
    }

    // MARK: Duplicates

    @Test("A second import of the same identifier asks, and leaves nothing behind")
    func duplicateByIdentifier() async throws {
        defer { cleanUp() }
        let first = try await writeEPUB(named: "One.epub", package: Self.package(identifier: "urn:isbn:1"))
        let second = try await writeEPUB(named: "Two.epub", package: Self.package(identifier: "urn:isbn:1"))
        _ = try await importer.importBook(from: first, bookId: "B1")

        await #expect(throws: BookImportError.duplicate(existingId: "B1", title: "The Tombs of Atuan")) {
            _ = try await importer.importBook(from: second, bookId: "B2")
        }
        #expect(try await repositories.books.fetchLibrary(LibraryQuery()).map(\.id) == ["B1"])
        #expect(!exists(files.url(forBookPath: "Books/local/B2.epub")))
    }

    @Test("Without an identifier, the same bytes are a duplicate and different bytes aren't")
    func duplicateByContent() async throws {
        defer { cleanUp() }
        let original = try await writeEPUB(named: "One.epub", package: Self.package(identifier: nil))
        let copy = root.appendingPathComponent("Copy.epub")
        try FileManager.default.copyItem(at: original, to: copy)
        let other = try await writeEPUB(named: "Other.epub", package: Self.package(identifier: nil, title: "Tehanu"))
        _ = try await importer.importBook(from: original, bookId: "B1")

        await #expect(throws: BookImportError.duplicate(existingId: "B1", title: "The Tombs of Atuan")) {
            _ = try await importer.importBook(from: copy)
        }
        _ = try await importer.importBook(from: other, bookId: "B3")
        #expect(try await repositories.books.fetchLibrary(LibraryQuery()).count == 2)
    }

    @Test("Keep Both imports a second book")
    func keepBoth() async throws {
        defer { cleanUp() }
        let source = try await writeEPUB(named: "One.epub", package: Self.package(identifier: "urn:isbn:1"))
        _ = try await importer.importBook(from: source, bookId: "B1")
        _ = try await importer.importBook(from: source, bookId: "B2", duplicates: .keepBoth)
        #expect(try await repositories.books.fetchLibrary(LibraryQuery()).count == 2)
    }

    @Test("Replace updates the book in place, keeping its id, reading state, and edited fields")
    func replace() async throws {
        defer { cleanUp() }
        let old = try await writeEPUB(named: "Old.epub", package: Self.package(identifier: "urn:isbn:1"))
        let new = try await writeEPUB(
            named: "New.epub",
            package: Self.package(identifier: "urn:isbn:1", title: "The Tombs of Atuan (Revised)", publisher: "Saga")
        )
        var book = try await importer.importBook(from: old, bookId: "B1")
        book.title = "My Tombs"
        book.isUserEdited = true
        book.userEditedFields = [.title]
        book.progression = 0.4
        try await repositories.books.save(book)

        let replaced = try await importer.importBook(from: new, bookId: "B2", duplicates: .replace("B1"))
        #expect(replaced.id == "B1")
        let stored = try #require(try await repositories.books.book(id: "B1"))
        #expect(stored.title == "My Tombs", "the user's title wins")
        #expect(stored.publisher == "Saga", "other fields come from the new file")
        #expect(stored.progression == 0.4)
        #expect(stored.localFilePath == "Books/local/B2.epub")
        #expect(try await repositories.books.fetchLibrary(LibraryQuery()).count == 1)
        #expect(!exists(files.url(forBookPath: "Books/local/B1.epub")), "the old file is removed")
        #expect(exists(files.url(forBookPath: "Books/local/B2.epub")))
    }

    // MARK: Fixtures

    /// An EPUB 3 package for "The Tombs of Atuan" by one author, optionally in the Earthsea series.
    private static func package(
        identifier: String?,
        title: String = "The Tombs of Atuan",
        publisher: String? = nil,
        series: Int? = nil
    ) -> String {
        let identifierElement = identifier.map { #"<dc:identifier id="uid">\#($0)</dc:identifier>"# } ?? ""
        let publisherElement = publisher.map { "<dc:publisher>\($0)</dc:publisher>" } ?? ""
        let seriesName = series == nil ? "" : #"<meta name="calibre:series" content="Earthsea"/>"#
        let seriesIndex = series.map { #"<meta name="calibre:series_index" content="\#($0)"/>"# } ?? ""
        return """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                \(identifierElement)
                <dc:title>\(title)</dc:title>
                <dc:creator>Ursula K. Le Guin</dc:creator>
                \(publisherElement)
                \(seriesName)\(seriesIndex)
              </metadata>
            </package>
            """
    }

    private func writeEPUB(named name: String, package: String, extra: [(String, Data)] = []) async throws -> URL {
        let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(container.utf8)),
            ("OEBPS/content.opf", Data(package.utf8)),
        ]
        entries += extra
        let url = root.appendingPathComponent(name)
        let archive = try await Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate,
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }
        return url
    }

    private struct FixtureError: Error {}

    private func pngData(width: Int, height: Int) throws -> Data {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw FixtureError() }
        context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw FixtureError() }
        let output = NSMutableData()
        let png = "public.png" as CFString
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, png, 1, nil) else {
            throw FixtureError()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError() }
        return output as Data
    }
}
