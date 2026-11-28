import Core
import Testing

@Suite("PlaceholderCover")
struct PlaceholderCoverTests {
    @Test("The tint is stable and in range")
    func stableTint() {
        // FNV-1a of "" is the offset basis; pinned so a change to the hash (and every book's colour) is noticed.
        #expect(PlaceholderCover.tintIndex(for: "", count: 1_000) == Int(UInt64(0xcbf2_9ce4_8422_2325) % 1_000))
        for title in ["Unknown Title", "The Tombs of Atuan", "Anathem", "Théâtre Noir"] {
            let index = PlaceholderCover.tintIndex(for: title, count: 8)
            #expect((0..<8).contains(index))
            #expect(PlaceholderCover.tintIndex(for: title, count: 8) == index)
        }
    }

    @Test("Different titles spread over the tints")
    func spread() {
        let titles = (1...40).map { "Book \($0)" }
        let used = Set(titles.map { PlaceholderCover.tintIndex(for: $0, count: 8) })
        #expect(used.count >= 6)
    }

    @Test("A count of zero or less gives 0")
    func noTints() {
        #expect(PlaceholderCover.tintIndex(for: "Anathem", count: 0) == 0)
        #expect(PlaceholderCover.tintIndex(for: "Anathem", count: -3) == 0)
    }
}
