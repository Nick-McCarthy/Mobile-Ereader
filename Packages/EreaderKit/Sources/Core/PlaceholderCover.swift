/// The generated cover for a book without one: title and author on a tint picked from the title. The pick uses
/// FNV-1a rather than `Hasher`, whose seed changes on every launch, so a book keeps its colour.
/// See docs/EPUB_METADATA.md and docs/UI_SPEC.md#library.
public enum PlaceholderCover {
    /// An index in `0..<count` (0 if `count` isn't positive), the same for the same title on every launch.
    public static func tintIndex(for title: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in title.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(count))
    }
}
