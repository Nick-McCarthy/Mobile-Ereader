import Core
import Testing

@Suite("TitleSortKey")
struct TitleSortKeyTests {
    @Test(
        "Leading articles are dropped, case and accents folded",
        arguments: [
            ("The Hobbit", "hobbit"),
            ("A Wizard of Earthsea", "wizard of earthsea"),
            ("An Instance of the Fingerpost", "instance of the fingerpost"),
            ("  THE   Left Hand of Darkness ", "left hand of darkness"),
            ("Anathem", "anathem"),
            ("Théâtre Noir", "theatre noir"),
            ("The", "the"),
            ("Theory of Everything", "theory of everything"),
        ]
    )
    func sortKey(title: String, expected: String) {
        #expect(TitleSortKey.make(from: title) == expected)
    }
}
