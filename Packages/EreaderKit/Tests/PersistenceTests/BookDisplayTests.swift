import Core
import Persistence
import Testing

@Suite("Book display")
struct BookDisplayTests {
    private func book(_ state: DownloadState, missing: Bool = false) -> Book {
        var book = Book(sourceKind: .iCloud, title: "Anathem", authorRaw: "Neal Stephenson")
        book.downloadState = state
        book.isMissingFromSource = missing
        return book
    }

    @Test("The stored state gives the file status")
    func storedState() {
        #expect(book(.downloaded).fileStatus(downloadProgress: nil) == .downloaded)
        #expect(book(.notDownloaded).fileStatus(downloadProgress: nil) == .notDownloaded)
        #expect(book(.downloading).fileStatus(downloadProgress: nil) == .downloading(progress: nil))
        #expect(book(.failed).fileStatus(downloadProgress: nil) == .failed)
    }

    @Test("A missing book shows as missing unless a copy is downloaded")
    func missing() {
        #expect(book(.notDownloaded, missing: true).fileStatus(downloadProgress: nil) == .missingFromSource)
        #expect(book(.downloaded, missing: true).fileStatus(downloadProgress: nil) == .downloaded)
    }

    @Test("A running download wins over the stored state, clamped to 0…1")
    func runningDownload() {
        #expect(book(.notDownloaded).fileStatus(downloadProgress: 0.25) == .downloading(progress: 0.25))
        #expect(book(.failed).fileStatus(downloadProgress: 1.5) == .downloading(progress: 1))
        #expect(book(.downloaded).fileStatus(downloadProgress: -1) == .downloading(progress: 0))
    }

    @Test(
        "Reading percent: nil when not started, at least 1, 100 only when finished",
        arguments: [
            (0.0, nil), (-0.2, nil), (0.001, 1), (0.42, 42), (0.426, 43), (0.996, 99), (1.0, 100), (1.2, 100),
        ] as [(Double, Int?)]
    )
    func readingPercent(progression: Double, expected: Int?) {
        var book = book(.downloaded)
        book.progression = progression
        #expect(book.readingPercent == expected)
    }

    @Test("The year comes from the sortable date")
    func year() {
        var book = book(.downloaded)
        #expect(book.publicationYear == nil)
        book.publicationDateSort = 1971_0000
        #expect(book.publicationYear == 1971)
        book.publicationDateSort = 2008_0909
        #expect(book.publicationYear == 2008)
        book.publicationDateSort = 0
        #expect(book.publicationYear == nil)
    }
}
