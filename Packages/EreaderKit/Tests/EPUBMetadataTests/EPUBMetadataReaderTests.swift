import Foundation
import ReadiumZIPFoundation
import Testing

@testable import EPUBMetadata

@Suite("EPUB metadata reader")
struct EPUBMetadataReaderTests {
    // MARK: Metadata

    @Test("EPUB 2: roles, file-as, publication event, Calibre series, meta cover", arguments: [true, false])
    func epub2(compressed: Bool) async throws {
        let package = EPUBFixture.package(
            version: "2.0",
            metadata: """
                <dc:title>A Wizard of Earthsea</dc:title>
                <dc:creator opf:role="aut" opf:file-as="Le Guin, Ursula K.">Ursula K. Le Guin</dc:creator>
                <dc:creator opf:role="ill">Ruth Robbins</dc:creator>
                <dc:date opf:event="modification">2012-01-01</dc:date>
                <dc:date opf:event="publication">1968-11</dc:date>
                <dc:language>en</dc:language>
                <dc:publisher>Parnassus</dc:publisher>
                <dc:identifier opf:scheme="calibre">calibre-id</dc:identifier>
                <dc:identifier id="uid">urn:isbn:9780000000001</dc:identifier>
                <meta name="cover" content="img-front"/>
                <meta name="calibre:series" content="Earthsea"/>
                <meta name="calibre:series_index" content="1.0"/>
                """,
            manifest: #"<item id="img-front" href="images/front.png" media-type="image/png"/>"#
        )
        let url = try await EPUBFixture.book(
            package: package,
            extra: [("OEBPS/images/front.png", try EPUBFixture.png(width: 1200, height: 800))],
            compression: compressed ? .deflate : .none
        )
        defer { EPUBFixture.cleanUp(url) }

        let metadata = try await EPUBMetadataReader.read(fileAt: url)
        #expect(metadata.version == "2.0")
        #expect(metadata.title == "A Wizard of Earthsea")
        #expect(metadata.authors == [EPUBAuthor(name: "Ursula K. Le Guin", fileAs: "Le Guin, Ursula K.")])
        #expect(metadata.publicationDate == "1968-11")
        #expect(metadata.publicationDateSort == 19_681_100)
        #expect(metadata.language == "en")
        #expect(metadata.publisher == "Parnassus")
        #expect(metadata.identifier == "urn:isbn:9780000000001")
        #expect(metadata.seriesName == "Earthsea")
        #expect(metadata.seriesPosition == 1)
        #expect(metadata.coverPath == "OEBPS/images/front.png")

        let thumbnail = try #require(metadata.coverThumbnail)
        let size = try #require(EPUBFixture.pixelSize(of: thumbnail))
        #expect(size.width == 600 && size.height == 400)
    }

    @Test("EPUB 3: main title, refined roles and file-as, collection series, cover-image property")
    func epub3() async throws {
        let package = EPUBFixture.package(
            uniqueIdentifier: "pub-id",
            metadata: """
                <dc:identifier id="pub-id">urn:uuid:1234</dc:identifier>
                <dc:title id="t2">An Earthsea Novel</dc:title>
                <meta refines="#t2" property="title-type">subtitle</meta>
                <dc:title id="t1">The Farthest Shore</dc:title>
                <meta refines="#t1" property="title-type">main</meta>
                <dc:creator id="c1">Ursula K. Le Guin</dc:creator>
                <meta refines="#c1" property="role" scheme="marc:relators">aut</meta>
                <meta refines="#c1" property="file-as">Le Guin, Ursula K.</meta>
                <dc:creator id="c2">Jane Editor</dc:creator>
                <meta refines="#c2" property="role" scheme="marc:relators">edt</meta>
                <dc:creator id="c3">Second Author</dc:creator>
                <dc:date>1972-09-01T00:00:00Z</dc:date>
                <meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>
                <meta property="belongs-to-collection" id="s1">Earthsea Cycle</meta>
                <meta refines="#s1" property="collection-type">series</meta>
                <meta refines="#s1" property="group-position">3</meta>
                """,
            manifest: """
                <item id="old" href="images/cover-old.png" media-type="image/png"/>
                <item id="art" href="images/Front%20Art.png" media-type="image/png" properties="cover-image"/>
                """
        )
        let url = try await EPUBFixture.book(
            package: package,
            extra: [
                ("OEBPS/images/Front Art.png", try EPUBFixture.png(width: 300, height: 450)),
                ("OEBPS/images/cover-old.png", try EPUBFixture.png(width: 10, height: 10)),
            ]
        )
        defer { EPUBFixture.cleanUp(url) }

        let metadata = try await EPUBMetadataReader.read(fileAt: url)
        #expect(metadata.title == "The Farthest Shore")
        #expect(
            metadata.authors == [
                EPUBAuthor(name: "Ursula K. Le Guin", fileAs: "Le Guin, Ursula K."),
                EPUBAuthor(name: "Second Author"),
            ]
        )
        #expect(metadata.authorDisplayName == "Ursula K. Le Guin & Second Author")
        #expect(metadata.publicationDate == "1972-09-01")
        #expect(metadata.publicationDateSort == 19_720_901)
        #expect(metadata.identifier == "urn:uuid:1234")
        #expect(metadata.seriesName == "Earthsea Cycle")
        #expect(metadata.seriesPosition == 3)
        #expect(metadata.coverPath == "OEBPS/images/Front Art.png")

        // Smaller than the thumbnail limit, so it keeps its size.
        let thumbnail = try #require(metadata.coverThumbnail)
        let size = try #require(EPUBFixture.pixelSize(of: thumbnail))
        #expect(size.width == 300 && size.height == 450)
    }

    @Test("Missing fields come back nil")
    func missingFields() async throws {
        let url = try await EPUBFixture.book(package: EPUBFixture.package(metadata: "<dc:title>  </dc:title>"))
        defer { EPUBFixture.cleanUp(url) }

        let metadata = try await EPUBMetadataReader.read(fileAt: url)
        #expect(metadata.title == nil)
        #expect(metadata.authors.isEmpty)
        #expect(metadata.authorDisplayName == nil)
        #expect(metadata.publicationDate == nil)
        #expect(metadata.publicationDateSort == nil)
        #expect(metadata.seriesName == nil)
        #expect(metadata.coverThumbnail == nil)
    }

    // MARK: Cover discovery

    @Test("Cover from a manifest image whose id or href mentions 'cover'")
    func coverByName() async throws {
        let package = EPUBFixture.package(
            metadata: "<dc:title>Book</dc:title>",
            manifest: #"<item id="pic" href="Images/Cover.png" media-type="image/png"/>"#
        )
        let url = try await EPUBFixture.book(
            opfPath: "content.opf",
            package: package,
            extra: [("Images/Cover.png", try EPUBFixture.png(width: 100, height: 150))]
        )
        defer { EPUBFixture.cleanUp(url) }

        let metadata = try await EPUBMetadataReader.read(fileAt: url)
        #expect(metadata.coverPath == "Images/Cover.png")
        #expect(metadata.coverThumbnail != nil)
    }

    @Test("Cover from the guide's cover page")
    func coverFromGuide() async throws {
        let page = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:xlink="http://www.w3.org/1999/xlink"><body>
            <svg viewBox="0 0 1 1"><image width="1" height="1" xlink:href="../Images/front.png"/></svg>
            </body></html>
            """
        let package = EPUBFixture.package(
            version: "2.0",
            metadata: "<dc:title>Book</dc:title>",
            manifest: """
                <item id="p1" href="Text/titlepage.xhtml" media-type="application/xhtml+xml"/>
                <item id="i1" href="Images/front.png" media-type="image/png"/>
                """,
            guide: #"<reference type="cover" title="Cover" href="Text/titlepage.xhtml"/>"#
        )
        let url = try await EPUBFixture.book(
            package: package,
            extra: [
                ("OEBPS/Text/titlepage.xhtml", Data(page.utf8)),
                ("OEBPS/Images/front.png", try EPUBFixture.png(width: 100, height: 150)),
            ]
        )
        defer { EPUBFixture.cleanUp(url) }

        let metadata = try await EPUBMetadataReader.read(fileAt: url)
        #expect(metadata.coverPath == "OEBPS/Images/front.png")
        #expect(metadata.coverThumbnail != nil)
    }

    @Test("An undecodable cover is skipped and the next candidate is used")
    func brokenCover() async throws {
        let package = EPUBFixture.package(
            metadata: #"<dc:title>Book</dc:title><meta name="cover" content="good"/>"#,
            manifest: """
                <item id="bad" href="bad.jpg" media-type="image/jpeg" properties="cover-image"/>
                <item id="good" href="good.png" media-type="image/png"/>
                """
        )
        let url = try await EPUBFixture.book(
            package: package,
            extra: [
                ("OEBPS/bad.jpg", Data("not an image".utf8)),
                ("OEBPS/good.png", try EPUBFixture.png(width: 20, height: 30)),
            ]
        )
        defer { EPUBFixture.cleanUp(url) }

        let metadata = try await EPUBMetadataReader.read(fileAt: url)
        #expect(metadata.title == "Book")
        #expect(metadata.coverPath == "OEBPS/good.png")
    }

    @Test("The first image on a cover page is found with either img or SVG image")
    func firstImageOnPage() {
        let html = Data(#"<p>x</p><IMG class="c" SRC='../img/a%20b.jpg#frag'/><img src="second.jpg"/>"#.utf8)
        #expect(EPUBMetadataReader.firstImage(inPage: html, at: "OEBPS/Text/p.xhtml") == "OEBPS/img/a b.jpg")
        #expect(EPUBMetadataReader.firstImage(inPage: Data("<p>none</p>".utf8), at: "p.xhtml") == nil)
    }

    // MARK: Malformed and hostile archives

    @Test("A file that isn't a ZIP is unreadable")
    func notAZip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: url)

        await #expect(throws: EPUBMetadataError.unreadableArchive) {
            _ = try await EPUBMetadataReader.read(fileAt: url)
        }
    }

    @Test("Missing container, missing rootfile, and missing package document are reported")
    func missingStructure() async throws {
        let noContainer = try await EPUBFixture.write([("mimetype", Data("application/epub+zip".utf8))])
        defer { EPUBFixture.cleanUp(noContainer) }
        await #expect(throws: EPUBMetadataError.missingEntry("META-INF/container.xml")) {
            _ = try await EPUBMetadataReader.read(fileAt: noContainer)
        }

        let noRootfile = try await EPUBFixture.write([("META-INF/container.xml", Data("<container/>".utf8))])
        defer { EPUBFixture.cleanUp(noRootfile) }
        await #expect(throws: EPUBMetadataError.missingPackageDocument) {
            _ = try await EPUBMetadataReader.read(fileAt: noRootfile)
        }

        let noPackage = try await EPUBFixture.write([
            ("META-INF/container.xml", EPUBFixture.container(opfPath: "OEBPS/content.opf"))
        ])
        defer { EPUBFixture.cleanUp(noPackage) }
        await #expect(throws: EPUBMetadataError.missingEntry("OEBPS/content.opf")) {
            _ = try await EPUBMetadataReader.read(fileAt: noPackage)
        }
    }

    @Test(
        "Broken XML, entity declarations, and deep nesting are rejected",
        arguments: [
            "<package><metadata>",
            #"<?xml version="1.0"?><!DOCTYPE p [<!ENTITY a "aaaa">]><package version="3.0">&a;</package>"#,
            String(repeating: "<a>", count: 100) + String(repeating: "</a>", count: 100),
        ]
    )
    func hostileXML(package: String) async throws {
        let url = try await EPUBFixture.book(package: package)
        defer { EPUBFixture.cleanUp(url) }
        await #expect(throws: EPUBMetadataError.malformedXML("OEBPS/content.opf")) {
            _ = try await EPUBMetadataReader.read(fileAt: url)
        }
    }

    @Test("Entry-count and entry-size limits are enforced")
    func limits() async throws {
        let url = try await EPUBFixture.book(package: EPUBFixture.package(metadata: "<dc:title>Book</dc:title>"))
        defer { EPUBFixture.cleanUp(url) }

        var fewEntries = EPUBLimits()
        fewEntries.maxEntryCount = 2
        await #expect(throws: EPUBMetadataError.tooManyEntries) {
            _ = try await EPUBMetadataReader.read(fileAt: url, limits: fewEntries)
        }

        var smallEntries = EPUBLimits()
        smallEntries.maxEntryBytes = 400
        await #expect(throws: EPUBMetadataError.entryTooLarge("OEBPS/content.opf")) {
            _ = try await EPUBMetadataReader.read(fileAt: url, limits: smallEntries)
        }
    }

    @Test("An entry that inflates far beyond its compressed size is refused")
    func compressionBomb() async throws {
        let url = try await EPUBFixture.write([("bomb.bin", Data(count: 4 * 1024 * 1024))])
        defer { EPUBFixture.cleanUp(url) }

        let archive = try await EPUBArchive(fileURL: url, limits: .standard)
        await #expect(throws: EPUBMetadataError.entryTooLarge("bomb.bin")) {
            _ = try await archive.data(at: "bomb.bin")
        }
    }
}

@Suite("EPUB metadata helpers")
struct EPUBMetadataHelperTests {
    @Test(
        "Publication dates",
        arguments: [
            ("1998", "1998", 19_980_000),
            ("1998-07", "1998-07", 19_980_700),
            ("1998-07-14", "1998-07-14", 19_980_714),
            ("2008-09-01T00:00:00Z", "2008-09-01", 20_080_901),
            ("2008-09-01 10:00", "2008-09-01", 20_080_901),
        ]
    )
    func validDates(raw: String, iso: String, sortKey: Int) throws {
        let date = try #require(PublicationDate(parsing: raw))
        #expect(date.isoString == iso)
        #expect(date.sortKey == sortKey)
    }

    @Test(
        "Unparseable dates are nil",
        arguments: ["", "July 1998", "98", "1998-13", "1998-07-32", "+998", "0101-01-01T00:00:00+00:00", "1998/07"]
    )
    func invalidDates(raw: String) {
        #expect(PublicationDate(parsing: raw) == nil)
    }

    @Test(
        "Archive paths resolve relative to the linking file",
        arguments: [
            ("OEBPS", "images/a.png", "OEBPS/images/a.png"),
            ("OEBPS/Text", "../Images/a%20b.png", "OEBPS/Images/a b.png"),
            ("OEBPS", "./c.xhtml#part2", "OEBPS/c.xhtml"),
            ("", "content.opf", "content.opf"),
        ]
    )
    func resolvePaths(directory: String, href: String, expected: String) {
        #expect(ArchivePath.resolve(href, relativeTo: directory) == expected)
    }

    @Test("Links that leave the archive resolve to nil", arguments: ["../../x.png", "/etc/passwd", "https://x/y.png"])
    func escapingPaths(href: String) {
        #expect(ArchivePath.resolve(href, relativeTo: "OEBPS") == nil)
    }
}
