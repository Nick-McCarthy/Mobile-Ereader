import Foundation

/// Reads a file's `isExcludedFromBackup`, waiting up to `timeout` for it to read as `expected`, and returns the
/// last value read. Assert on the result, so a flag that never reaches `expected` still fails the test.
///
/// On macOS, where `swift test` runs, the flag settles after a delay. A read soon after a write can return the
/// previous value, even when the write succeeded and the same URL read it back correctly just before. In CI
/// (action plan A1.11) a cleared flag read `true` for up to about 0.45 s, then `false` for good.
func backupExclusion(
    of url: URL,
    settlingOn expected: Bool,
    timeout: Duration = .seconds(5)
) async throws -> Bool? {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while true {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let value = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        if value == expected || clock.now >= deadline { return value }
        try await Task.sleep(for: .milliseconds(20))
    }
}
