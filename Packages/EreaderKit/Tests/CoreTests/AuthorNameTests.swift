import Core
import Testing

/// One row of the tricky-names table in docs/EPUB_METADATA.md#author-name-normalisation.
struct AuthorCase: Sendable, CustomTestStringConvertible {
    var raw: String
    var fileAs: String?
    var format: AuthorStoredFormat
    var given: String?
    var family: String?
    var firstLast: String
    var lastFirst: String

    var testDescription: String { raw }
}

@Suite("Author names")
struct AuthorNameTests {
    static let cases: [AuthorCase] = [
        AuthorCase(
            raw: "Le Guin, Ursula K.",
            format: .lastFirst,
            given: "Ursula K.",
            family: "Le Guin",
            firstLast: "Ursula K. Le Guin",
            lastFirst: "Le Guin, Ursula K."
        ),
        AuthorCase(
            raw: "Ursula K. Le Guin",
            format: .firstLast,
            given: "Ursula K.",
            family: "Le Guin",
            firstLast: "Ursula K. Le Guin",
            lastFirst: "Le Guin, Ursula K."
        ),
        AuthorCase(
            raw: "Tolkien, J. R. R.",
            format: .lastFirst,
            given: "J. R. R.",
            family: "Tolkien",
            firstLast: "J. R. R. Tolkien",
            lastFirst: "Tolkien, J. R. R."
        ),
        AuthorCase(
            raw: "Martin Luther King, Jr.",
            format: .firstLast,
            given: "Martin Luther",
            family: "King",
            firstLast: "Martin Luther King Jr.",
            lastFirst: "King, Martin Luther, Jr."
        ),
        AuthorCase(
            raw: "King, Martin Luther, Jr.",
            format: .lastFirst,
            given: "Martin Luther",
            family: "King",
            firstLast: "Martin Luther King Jr.",
            lastFirst: "King, Martin Luther, Jr."
        ),
        AuthorCase(
            raw: "Homer",
            format: .firstLast,
            given: nil,
            family: "Homer",
            firstLast: "Homer",
            lastFirst: "Homer"
        ),
        AuthorCase(
            raw: "Gabriel García Márquez",
            format: .firstLast,
            given: "Gabriel García",
            family: "Márquez",
            firstLast: "Gabriel García Márquez",
            lastFirst: "Márquez, Gabriel García"
        ),
        // The book's file-as fixes a double surname the heuristic can't know about.
        AuthorCase(
            raw: "Gabriel García Márquez",
            fileAs: "García Márquez, Gabriel",
            format: .firstLast,
            given: "Gabriel",
            family: "García Márquez",
            firstLast: "Gabriel García Márquez",
            lastFirst: "García Márquez, Gabriel"
        ),
        AuthorCase(
            raw: "Bob Smith & Jane Doe",
            format: .firstLast,
            given: "Bob",
            family: "Smith",
            firstLast: "Bob Smith & Jane Doe",
            lastFirst: "Smith, Bob & Doe, Jane"
        ),
        AuthorCase(
            raw: "Smith, Bob; Doe, Jane",
            format: .lastFirst,
            given: "Bob",
            family: "Smith",
            firstLast: "Bob Smith & Jane Doe",
            lastFirst: "Smith, Bob & Doe, Jane"
        ),
        AuthorCase(
            raw: "Ludwig van  Beethoven",
            format: .firstLast,
            given: "Ludwig",
            family: "van Beethoven",
            firstLast: "Ludwig van Beethoven",
            lastFirst: "van Beethoven, Ludwig"
        ),
        AuthorCase(
            raw: "Van Morrison",
            format: .firstLast,
            given: "Van",
            family: "Morrison",
            firstLast: "Van Morrison",
            lastFirst: "Morrison, Van"
        ),
        AuthorCase(
            raw: "Project Gutenberg",
            format: .unknown,
            given: nil,
            family: nil,
            firstLast: "Project Gutenberg",
            lastFirst: "Project Gutenberg"
        ),
        AuthorCase(
            raw: "Smith, John, Esq., London",
            format: .unknown,
            given: nil,
            family: nil,
            firstLast: "Smith, John, Esq., London",
            lastFirst: "Smith, John, Esq., London"
        ),
    ]

    @Test("Tricky names: detection, parts, and both display formats", arguments: cases)
    func trickyNames(_ example: AuthorCase) {
        let name = AuthorName(raw: example.raw, fileAs: example.fileAs)
        #expect(name.storedFormat == example.format)
        #expect(name.primary?.given == example.given)
        #expect(name.primary?.family == example.family)
        #expect(AuthorNameFormatter.string(for: name, in: .firstLast) == example.firstLast)
        #expect(AuthorNameFormatter.string(for: name, in: .lastFirst) == example.lastFirst)
        #expect(AuthorNameFormatter.string(for: name, in: .asStored) == example.raw)
    }

    @Test("A stored format chosen by the user overrides detection")
    func userOverride() {
        // Detected as "Last, First", but the user says the comma is part of a "First Last" name.
        let name = AuthorName(raw: "Prince, The Artist", storedFormat: .firstLast)
        #expect(name.primary?.family == "Artist")
        #expect(AuthorNameFormatter.string(for: name, in: .lastFirst) == "Artist, Prince The")

        let unknown = AuthorName(raw: "Le Guin, Ursula K.", storedFormat: .unknown)
        #expect(unknown.people.isEmpty)
        #expect(AuthorNameFormatter.string(for: unknown, in: .firstLast) == "Le Guin, Ursula K.")
    }

    @Test("Display formats have stable raw values for UserDefaults")
    func displayFormatRawValues() {
        #expect(AuthorDisplayFormat.allCases.map(\.rawValue) == ["asStored", "firstLast", "lastFirst"])
    }
}
