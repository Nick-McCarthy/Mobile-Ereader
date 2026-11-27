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
        importer = LocalBookImporter(books: repositories.books, files: files)
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

    // MARK: Fixtures

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
