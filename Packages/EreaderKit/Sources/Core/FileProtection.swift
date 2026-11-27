import Foundation

/// Applies the app's Data Protection class. A no-op on macOS, where `swift test` runs.
public enum FileProtection {
    // Computed: a stored `[FileAttributeKey: Any]` isn't Sendable, so it can't be a static `let` in Swift 6.
    public static var directoryAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
            return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
            return nil
        #endif
    }

    /// Creates `url` (and parents). Files created inside it later inherit its protection class.
    public static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
    }

    /// Sets the protection class on an existing file.
    public static func apply(to url: URL) throws {
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path(percentEncoded: false)
            )
        #endif
    }
}
