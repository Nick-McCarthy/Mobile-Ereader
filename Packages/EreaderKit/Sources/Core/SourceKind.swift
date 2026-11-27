/// Where a book in the library comes from. See docs/REMOTE_SOURCES.md.
public enum SourceKind: String, CaseIterable, Codable, Sendable {
    /// Imported onto the device from Files or the share sheet.
    case local
    /// A folder picked in iCloud Drive (or another Files provider).
    case iCloud
    case dropbox
    case oneDrive
}
