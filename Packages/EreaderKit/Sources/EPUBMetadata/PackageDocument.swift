import Foundation

/// The parts of an OPF package document the library uses, with EPUB 2 and EPUB 3 differences resolved.
struct PackageDocument: Sendable {
    struct ManifestItem: Sendable {
        var id: String
        /// Resolved to a path inside the archive.
        var path: String
        var mediaType: String
        var properties: [String]

        var isImage: Bool { mediaType.lowercased().hasPrefix("image/") }
    }

    var metadata = EPUBMetadata()
    var manifest: [ManifestItem] = []
    /// EPUB 2 `<meta name="cover" content="…">`: the manifest id of the cover image.
    var coverItemId: String?
    /// EPUB 2 `<guide><reference type="cover">`: the cover page, resolved to an archive path.
    var guideCoverPagePath: String?

    /// Builds the document from a parsed OPF located at `path` (hrefs are relative to its directory).
    init(root: MarkupElement, path: String) {
        let directory = ArchivePath.directory(of: path)
        guard let package = root.firstChild(named: "package") else { return }
        metadata.version = package["version"]

        let metadataElement = package.firstChild(named: "metadata") ?? MarkupElement(name: "metadata")
        let refinements = Refinements(metadataElement.descendants(named: "meta"))
        readMetadata(metadataElement, refinements: refinements, uniqueIdentifierId: package["unique-identifier"])

        for item in package.firstChild(named: "manifest")?.children(named: "item") ?? [] {
            guard let id = item["id"], let href = item["href"],
                let itemPath = ArchivePath.resolve(href, relativeTo: directory)
            else { continue }
            let properties = (item["properties"] ?? "").split(separator: " ").map(String.init)
            manifest.append(
                ManifestItem(id: id, path: itemPath, mediaType: item["media-type"] ?? "", properties: properties)
            )
        }

        let guideReferences = package.firstChild(named: "guide")?.children(named: "reference") ?? []
        let guideCover = guideReferences.first { $0["type"]?.lowercased() == "cover" }
        guideCoverPagePath = guideCover?["href"].flatMap { ArchivePath.resolve($0, relativeTo: directory) }
    }

    private mutating func readMetadata(
        _ element: MarkupElement,
        refinements: Refinements,
        uniqueIdentifierId: String?
    ) {
        let titles = element.descendants(named: "title").filter { $0.trimmedText != nil }
        let mainTitle = titles.first { refinements.value("title-type", for: $0["id"]) == "main" }
        metadata.title = (mainTitle ?? titles.first)?.trimmedText

        metadata.authors = Self.authors(element.descendants(named: "creator"), refinements: refinements)

        let dates = element.descendants(named: "date").filter { $0.trimmedText != nil }
        let publication = dates.first { $0["event"]?.lowercased() == "publication" } ?? dates.first
        if let raw = publication?.trimmedText, let date = PublicationDate(parsing: raw) {
            metadata.publicationDate = date.isoString
            metadata.publicationDateSort = date.sortKey
        }

        metadata.language = element.descendants(named: "language").first?.trimmedText
        metadata.publisher = element.descendants(named: "publisher").first?.trimmedText
        metadata.description = element.descendants(named: "description").first?.trimmedText
        let identifiers = element.descendants(named: "identifier").filter { $0.trimmedText != nil }
        let unique = identifiers.first { uniqueIdentifierId != nil && $0["id"] == uniqueIdentifierId }
        metadata.identifier = (unique ?? identifiers.first)?.trimmedText

        readSeries(metas: element.descendants(named: "meta"), refinements: refinements)
        coverItemId = element.descendants(named: "meta").first { $0["name"] == "cover" }?["content"]
    }

    /// Creators whose role is "aut" (EPUB 2 attribute or EPUB 3 refinement), plus creators with no role.
    private static func authors(_ creators: [MarkupElement], refinements: Refinements) -> [EPUBAuthor] {
        creators.compactMap { creator in
            guard let name = creator.trimmedText else { return nil }
            let id = creator["id"]
            let role = creator["role"] ?? refinements.value("role", for: id)
            guard role == nil || role?.lowercased() == "aut" else { return nil }
            let rawFileAs = creator["file-as"] ?? refinements.value("file-as", for: id) ?? ""
            let fileAs = rawFileAs.trimmingCharacters(in: .whitespacesAndNewlines)
            return EPUBAuthor(name: name, fileAs: fileAs.isEmpty ? nil : fileAs)
        }
    }

    /// EPUB 3 `belongs-to-collection` (type "series") first, then Calibre's `calibre:series` metas.
    private mutating func readSeries(metas: [MarkupElement], refinements: Refinements) {
        for meta in metas where meta["property"] == "belongs-to-collection" {
            guard let name = meta.trimmedText else { continue }
            let id = meta["id"]
            let type = refinements.value("collection-type", for: id)
            guard type == nil || type == "series" else { continue }
            metadata.seriesName = name
            metadata.seriesPosition = refinements.value("group-position", for: id).flatMap(Self.position)
            return
        }
        if let name = metas.first(where: { $0["name"] == "calibre:series" })?["content"], !name.isEmpty {
            metadata.seriesName = name
            let index = metas.first { $0["name"] == "calibre:series_index" }?["content"]
            metadata.seriesPosition = index.flatMap(Self.position)
        }
    }

    private static func position(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }
}

/// EPUB 3 `<meta refines="#id" property="…">value</meta>` lookups.
private struct Refinements {
    private var values: [String: [String: String]] = [:]

    init(_ metas: [MarkupElement]) {
        for meta in metas {
            guard let refines = meta["refines"], refines.hasPrefix("#"), let property = meta["property"],
                let value = meta.trimmedText
            else { continue }
            let id = String(refines.dropFirst())
            // Compare property names without any vocabulary prefix.
            let name = Markup.localName(property)
            if values[id, default: [:]][name] == nil {
                values[id, default: [:]][name] = value
            }
        }
    }

    func value(_ property: String, for id: String?) -> String? {
        guard let id else { return nil }
        return values[id]?[property]
    }
}
