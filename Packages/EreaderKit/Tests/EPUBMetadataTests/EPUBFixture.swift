import CoreGraphics
import Foundation
import ImageIO
import ReadiumZIPFoundation

/// Builds small synthetic EPUBs for tests, so no real (copyrighted) books are needed.
enum EPUBFixture {
    struct FixtureError: Error {}

    /// Writes `files` (archive path → contents) to a new archive in its own temporary directory.
    /// Delete the directory with `cleanUp(_:)`.
    static func write(_ files: [(String, Data)], compression: CompressionMethod = .deflate) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("book.epub")
        let archive = try await Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: compression,
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }
        return url
    }

    static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// A complete EPUB: mimetype, container pointing at `opfPath`, the package document, and `extra` files.
    static func book(
        opfPath: String = "OEBPS/content.opf",
        package: String,
        extra: [(String, Data)] = [],
        compression: CompressionMethod = .deflate
    ) async throws -> URL {
        var files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", container(opfPath: opfPath)),
            (opfPath, Data(package.utf8)),
        ]
        files += extra
        return try await write(files, compression: compression)
    }

    static func container(opfPath: String) -> Data {
        Data(
            """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8
        )
    }

    /// An OPF package document with the given `<metadata>` body, manifest items, and guide references.
    static func package(
        version: String = "3.0",
        uniqueIdentifier: String = "uid",
        metadata: String,
        manifest: String = "",
        guide: String = ""
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" unique-identifier="\(uniqueIdentifier)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            \(metadata)
          </metadata>
          <manifest>\(manifest)</manifest>
          <spine/>
          <guide>\(guide)</guide>
        </package>
        """
    }

    /// A solid-colour PNG of the given size.
    static func png(width: Int, height: Int) throws -> Data {
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
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
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

    /// Pixel width and height of encoded image data.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
