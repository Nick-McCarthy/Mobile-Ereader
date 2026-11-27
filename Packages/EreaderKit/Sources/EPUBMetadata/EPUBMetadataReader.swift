import Foundation

/// Reads title, authors, date, series, and cover from an EPUB file. See docs/EPUB_METADATA.md#parsing-steps.
public enum EPUBMetadataReader {
    /// Reads the metadata of the EPUB at `url`. Every EPUB is treated as untrusted: see `EPUBLimits`.
    /// Throws `EPUBMetadataError` when the archive or its package document can't be read. A missing or
    /// unreadable cover is not an error; `coverThumbnail` is just nil.
    public static func read(fileAt url: URL, limits: EPUBLimits = .standard) async throws -> EPUBMetadata {
        let archive = try await EPUBArchive(fileURL: url, limits: limits)
        return try await read(archive, limits: limits)
    }

    /// Reads the metadata of a remote EPUB through ranged reads, usually in 3–5 requests.
    ///
    /// If the server ignores ranges, or the archive can't be read remotely, `fallbackDownload` is asked to
    /// write the whole file to the temporary URL it is given; that copy is parsed and then deleted.
    /// Errors from `reader` (other than `ByteRangeError`) are rethrown as they are, so callers can see
    /// `RemoteSourceError.needsRelink`, rate limits, and network failures; they don't trigger the fallback.
    public static func read(
        remote reader: any ByteRangeReading,
        limits: EPUBLimits = .standard,
        fallbackDownload: (URL) async throws -> Void
    ) async throws -> EPUBMetadata {
        let source = RemoteZipReader(reader: reader)
        do {
            let archive = try await EPUBArchive(remote: source, limits: limits)
            let metadata = try await read(archive, limits: limits)
            // A failed read can also hide inside a skipped cover, so success counts only if none failed.
            if await source.cache.readerError == nil { return metadata }
        } catch EPUBMetadataError.unreadableArchive {
            // Unreadable remotely: a reader error is rethrown below, otherwise the full file is tried.
        } catch is ByteRangeError {
            // Ranged reads don't work for this file: fall back below.
        }
        if let readerError = await source.cache.readerError, !(readerError is ByteRangeError) {
            throw readerError
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "metadata-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("book.epub")
        try await fallbackDownload(file)
        return try await read(fileAt: file, limits: limits)
    }

    static func read(_ archive: EPUBArchive, limits: EPUBLimits) async throws -> EPUBMetadata {
        let packagePath = try await packageDocumentPath(in: archive, limits: limits)
        let packageData = try await archive.data(at: packagePath)
        guard let root = Markup.parse(packageData, maxDepth: limits.maxXMLDepth) else {
            throw EPUBMetadataError.malformedXML(packagePath)
        }
        let package = PackageDocument(root: root, path: packagePath)
        var metadata = package.metadata

        for path in await coverCandidates(package, archive: archive) {
            // Covers are optional: a candidate that is missing, too large, or not an image is skipped.
            guard let data = try? await archive.data(at: path),
                let thumbnail = CoverThumbnail.make(
                    from: data,
                    maxPixelSize: limits.thumbnailMaxPixelSize,
                    maxSourcePixels: limits.maxImagePixels
                )
            else { continue }
            metadata.coverPath = path
            metadata.coverThumbnail = thumbnail
            break
        }
        return metadata
    }

    /// The first `<rootfile>` in `META-INF/container.xml`, preferring one with the OPF media type.
    static func packageDocumentPath(in archive: EPUBArchive, limits: EPUBLimits) async throws -> String {
        let containerPath = "META-INF/container.xml"
        let data = try await archive.data(at: containerPath)
        guard let root = Markup.parse(data, maxDepth: limits.maxXMLDepth) else {
            throw EPUBMetadataError.malformedXML(containerPath)
        }
        let rootfiles = root.descendants(named: "rootfile")
        let rootfile = rootfiles.first { $0["media-type"] == "application/oebps-package+xml" } ?? rootfiles.first
        guard let href = rootfile?["full-path"], let path = ArchivePath.resolve(href, relativeTo: "") else {
            throw EPUBMetadataError.missingPackageDocument
        }
        return path
    }

    /// Cover image paths in the priority order of docs/EPUB_METADATA.md, without duplicates.
    static func coverCandidates(_ package: PackageDocument, archive: EPUBArchive) async -> [String] {
        var candidates: [String] = []
        // 1. EPUB 3 `properties="cover-image"`.
        candidates += package.manifest.filter { $0.properties.contains("cover-image") }.map(\.path)
        // 2. EPUB 2 `<meta name="cover">` naming a manifest item.
        if let id = package.coverItemId, let item = package.manifest.first(where: { $0.id == id }) {
            candidates.append(item.path)
        }
        // 3. An image whose id or href mentions "cover".
        let namedCovers = package.manifest.filter { item in
            item.isImage && (item.id.lowercased().contains("cover") || item.path.lowercased().contains("cover"))
        }
        candidates += namedCovers.map(\.path)
        // 4. The guide's cover page and the first image on it (some books point the guide straight at the image).
        if let pagePath = package.guideCoverPagePath {
            if package.manifest.contains(where: { $0.path == pagePath && $0.isImage }) {
                candidates.append(pagePath)
            } else if let page = try? await archive.data(at: pagePath),
                let imagePath = firstImage(inPage: page, at: pagePath)
            {
                candidates.append(imagePath)
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// The first `<img src>` or SVG `<image href>` in an XHTML page, resolved to an archive path.
    /// Uses a pattern match rather than an XML parser because cover pages are often not well-formed.
    static func firstImage(inPage page: Data, at pagePath: String) -> String? {
        let html = String(decoding: page, as: UTF8.self)
        let pattern = #"<(?:img|image)\b[^>]*?\s(?:src|xlink:href|href)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return ArchivePath.resolve(String(html[range]), relativeTo: ArchivePath.directory(of: pagePath))
    }
}
