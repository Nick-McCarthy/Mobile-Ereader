import UIKit

/// Loads cover thumbnails off the main actor and keeps the decoded images in memory, so the library never
/// reads or decodes a file inside a view's `body` (finding F-E1).
///
/// Covers are keyed by file URL. Cover files are written once per book id; anything that rewrites one in
/// place must call `forget(_:)`.
final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()

    /// `NSCache` is thread-safe, which is what makes the unchecked `Sendable` sound.
    private let cache = NSCache<NSURL, UIImage>()

    init(countLimit: Int = 300) {
        cache.countLimit = countLimit
    }

    /// The decoded cover, if it is already in memory. Cheap enough for `body`.
    func cachedImage(at url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Reads and decodes the cover on a background thread, then keeps it. Nil if the file is unreadable.
    @concurrent
    func image(at url: URL) async -> UIImage? {
        if let cached = cachedImage(at: url) { return cached }
        guard let decoded = UIImage(contentsOfFile: url.path(percentEncoded: false))?.preparingForDisplay() else {
            return nil
        }
        cache.setObject(decoded, forKey: url as NSURL)
        return decoded
    }

    func forget(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }
}
