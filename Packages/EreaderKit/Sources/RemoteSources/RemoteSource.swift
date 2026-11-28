import Core
import Foundation

/// One book service the user can link: iCloud Drive / Files, Dropbox, or OneDrive.
/// Adapters implement this; `SyncEngine` (P2.7) and the Settings UI (P2.8) use only this protocol.
/// See docs/REMOTE_SOURCES.md#source-model.
public protocol RemoteSource: Sendable {
    var kind: SourceKind { get }

    /// Signs in or grants access. Throws `RemoteSourceError.cancelled` if the user backs out.
    func link() async throws -> LinkedAccount
    /// Revokes access where the provider allows it and deletes local credentials. Never touches remote files.
    func unlink() async throws

    /// Sub-folders of `folder`, or of the top level when nil, for the folder browser.
    func listFolders(in folder: RemoteFolder?) async throws -> [RemoteFolder]

    /// Every `.epub` under `root`, recursively.
    ///
    /// With no cursor (or one the provider no longer accepts), the stream starts with `.reset` and lists every
    /// book. With a valid cursor it lists only changes since then. Either way it ends with `.cursor` to save for
    /// the next sync. The stream throws `RemoteSourceError` on failure.
    func enumerateEPUBs(under root: RemoteFolder, since cursor: SyncCursor?) -> RemoteChangeStream

    /// Ranged access to the file for reading metadata without a full download, or nil if not supported.
    func byteRangeReader(for file: RemoteFile) -> (any ByteRangeReading)?

    /// Downloads the whole file to `destination`, reporting progress from 0 to 1.
    func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// The stream `RemoteSource.enumerateEPUBs` returns.
public typealias RemoteChangeStream = AsyncThrowingStream<RemoteChange, any Error>

/// The account shown in Settings after linking. Kept on the device only.
public struct LinkedAccount: Equatable, Sendable {
    /// A display name or email; for iCloud Drive / Files, the picked folder's name.
    public var label: String?

    public init(label: String?) {
        self.label = label
    }
}

/// A folder in a remote source.
public struct RemoteFolder: Equatable, Hashable, Sendable {
    /// Provider id: a Dropbox `id:` or path, a Graph item id, or a path relative to the iCloud root.
    /// The empty string means the top of the drive.
    public var id: String
    public var name: String
    /// Shown in Settings, such as "/Books/Fiction".
    public var displayPath: String

    public init(id: String, name: String, displayPath: String) {
        self.id = id
        self.name = name
        self.displayPath = displayPath
    }

    /// The whole drive.
    public static let root = RemoteFolder(id: "", name: "", displayPath: "/")
}

/// An EPUB file in a remote source.
public struct RemoteFile: Equatable, Hashable, Sendable {
    /// Stable provider id. A book is unique per (source, remoteId).
    public var remoteId: String
    /// Path for display, such as "/Books/Fiction/Earthsea.epub".
    public var displayPath: String
    public var name: String
    public var size: Int64?
    /// Changes whenever the content changes: Dropbox `content_hash`, Graph `cTag`, or modified date + size.
    public var version: String
    public var modifiedAt: Date?

    public init(
        remoteId: String,
        displayPath: String,
        name: String,
        size: Int64?,
        version: String,
        modifiedAt: Date?
    ) {
        self.remoteId = remoteId
        self.displayPath = displayPath
        self.name = name
        self.size = size
        self.version = version
        self.modifiedAt = modifiedAt
    }
}

/// An opaque position in a source's change feed, saved in `library_source.syncCursor`.
public struct SyncCursor: Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One item from `RemoteSource.enumerateEPUBs`.
public enum RemoteChange: Equatable, Sendable {
    /// A full listing follows: any book of this source that isn't upserted before the final `.cursor` is
    /// missing from the source.
    case reset
    /// A book that is new or may have changed (compare `version`).
    case upsert(RemoteFile)
    /// A book that was deleted or moved out of the root folder.
    case removed(remoteId: String)
    /// The listing finished; save this for the next sync.
    case cursor(SyncCursor)
}

public enum RemoteSourceError: Error, Equatable, Sendable {
    /// The user cancelled sign-in or the folder picker.
    case cancelled
    /// Credentials or folder access are gone; the source must be linked again.
    case needsRelink
    /// The provider asked us to slow down. Retry after the given number of seconds, if known.
    case rateLimited(retryAfter: Double?)
    /// The file or folder no longer exists.
    case notFound
}
