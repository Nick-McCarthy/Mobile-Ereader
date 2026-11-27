import Core
import Testing

@Suite("Core")
struct CoreTests {
    @Test("Source kinds have stable raw values for the database")
    func sourceKindRawValues() {
        #expect(SourceKind.allCases.map(\.rawValue) == ["local", "iCloud", "dropbox", "oneDrive"])
    }

    @Test("Placeholders match the spec")
    func placeholders() {
        #expect(Placeholders.title == "Unknown Title")
        #expect(Placeholders.author == "Unknown Author")
        #expect(Placeholders.publicationDate == "Unknown")
    }
}
