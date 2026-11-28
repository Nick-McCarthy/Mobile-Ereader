import Foundation
import ReadiumZIPFoundation

/// Minimal EPUBs for the LibraryServices tests.
enum EPUBBytes {
    /// A minimal EPUB's bytes.
    static func make(title: String, author: String? = nil, series: (String, Double)? = nil) async throws -> Data {
        var metadata = "<dc:title>\(title)</dc:title>"
        if let author { metadata += "<dc:creator>\(author)</dc:creator>" }
        if let series {
            metadata += """
                <meta property="belongs-to-collection" id="s1">\(series.0)</meta>
                <meta refines="#s1" property="collection-type">series</meta>
                <meta refines="#s1" property="group-position">\(series.1)</meta>
                """
        }
        let package = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\(metadata)</metadata>
              <manifest/>
            </package>
            """
        let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """
        let entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(container.utf8)),
            ("OEBPS/content.opf", Data(package.utf8)),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try await Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate,
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) }
            )
        }
        return try Data(contentsOf: url)
    }
}
