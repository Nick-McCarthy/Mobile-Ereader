import Foundation

/// Directory walking for `FilesRemoteSource`, kept free of bookmarks and security scope so tests can run
/// it on a temporary directory.
enum FilesListing {
    static let placeholderSuffix = ".icloud"

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey,
        .ubiquitousItemDownloadingStatusKey,
    ]

    /// Every `.epub` under `start`, with ids relative to `root`, sorted by id. Hidden folders and packages
    /// are skipped. iCloud placeholders (`.Name.epub.icloud`) are listed under their real name.
    static func epubs(under start: URL, root: URL) throws -> [RemoteFile] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: start,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }  // An unreadable sub-folder shouldn't stop the whole listing.
            )
        else { throw RemoteSourceError.notFound }

        var files: [String: RemoteFile] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            guard let realName = epubName(forFileNamed: name) else { continue }
            let realURL = url.deletingLastPathComponent().appendingPathComponent(realName)
            // Relative to the listed URL, which exists (a placeholder's real file may not).
            guard let listedId = relativePath(of: url, in: root) else { continue }
            let id = String(listedId.dropLast(name.count)) + realName
            // Prefer the real file's values; a placeholder's own size and date describe the placeholder.
            let real = try? realURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let isPlaceholder = realName != name
            let size = real?.fileSize ?? (isPlaceholder ? nil : values?.fileSize)
            let modified = real?.contentModificationDate ?? values?.contentModificationDate
            let file = RemoteFile(
                remoteId: id,
                displayPath: "/" + root.lastPathComponent + "/" + id,
                name: realName,
                size: size.map(Int64.init),
                version: version(modified: modified, size: size),
                modifiedAt: modified
            )
            // A downloaded file wins over a leftover placeholder with the same name.
            if files[id] == nil || !isPlaceholder { files[id] = file }
        }
        return files.values.sorted { $0.remoteId < $1.remoteId }
    }

    /// Visible sub-folders of `folder` (whose id is `id`), sorted as Files sorts them.
    static func subfolders(of folder: URL, id: String, rootName: String) throws -> [RemoteFolder] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw RemoteSourceError.notFound
        }
        let folders = contents.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
        let subfolders = folders.map { url in
            let name = url.lastPathComponent
            let childId = id.isEmpty ? name : id + "/" + name
            return RemoteFolder(id: childId, name: name, displayPath: "/" + rootName + "/" + childId)
        }
        return subfolders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The EPUB's real name for a listed file name: itself, or the name inside an iCloud placeholder.
    /// Nil for anything that isn't an EPUB, and for other hidden files.
    static func epubName(forFileNamed name: String) -> String? {
        var realName = name
        if name.hasPrefix("."), name.hasSuffix(placeholderSuffix) {
            realName = String(name.dropFirst().dropLast(placeholderSuffix.count))
        } else if name.hasPrefix(".") {
            return nil
        }
        guard !realName.isEmpty, realName.lowercased().hasSuffix(".epub") else { return nil }
        return realName
    }

    /// The placeholder iCloud shows in place of `url` while the file isn't downloaded.
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + placeholderSuffix)
    }

    /// Changes whenever the content does, as far as a file system can tell.
    static func version(modified: Date?, size: Int?) -> String {
        let milliseconds = modified.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "?"
        return milliseconds + "-" + (size.map(String.init) ?? "?")
    }

    /// `id` (a relative path) inside `root`. Rejects ids that would escape the folder.
    static func url(for id: String, in root: URL) throws -> URL {
        let components = id.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { throw RemoteSourceError.notFound }
        return components.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// `url`'s path relative to `root`, or nil if it isn't inside it.
    static func relativePath(of url: URL, in root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.count > rootComponents.count, components.starts(with: rootComponents) else { return nil }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether the file's bytes are on the device. Files outside iCloud always are.
    static func isDownloaded(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return true }
        return values?.ubiquitousItemDownloadingStatus == .current
    }
}
