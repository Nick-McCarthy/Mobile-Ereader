import Core
import Foundation
import Persistence
import Testing

/// A whole-second date, so it survives GRDB's millisecond date storage unchanged.
private func day(_ n: Int) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400)
}

private func makeBook(
    _ id: String,
    title: String?,
    author: String? = "Someone",
    family: String? = nil,
    given: String? = nil,
    year: Int? = nil,
    added: Int = 0,
    opened: Int? = nil,
    state: DownloadState = .notDownloaded
) -> Book {
    var book = Book(id: id, sourceKind: .local, title: title, authorRaw: author, dateAdded: day(added))
    book.authorFamily = family
    book.authorGiven = given
    book.publicationDateSort = year
    book.lastOpenedAt = opened.map(day)
    book.downloadState = state
    return book
}

@Suite("Book repository")
struct BookRepositoryTests {
    let repositories: DatabaseRepositories

    init() throws {
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
    }

    private func ids(_ query: LibraryQuery) async throws -> [String] {
        try await repositories.books.fetchLibrary(query).map(\.id)
    }

    private func save(_ books: Book...) async throws {
        for book in books { try await repositories.books.save(book) }
    }

    @Test("A saved book reads back unchanged, and saving again updates it")
    func roundTrip() async throws {
        var book = makeBook("b1", title: "The Dispossessed", year: 1974, opened: 3, state: .downloaded)
        book.userEditedFields = [.title, .cover]
        book.isUserEdited = true
        book.progression = 0.25
        try await repositories.books.save(book)
        #expect(try await repositories.books.book(id: "b1") == book)

        book.title = "Renamed"
        try await repositories.books.save(book)
        #expect(try await repositories.books.book(id: "b1")?.title == "Renamed")

        try await repositories.books.deleteBook(id: "b1")
        #expect(try await repositories.books.book(id: "b1") == nil)
    }

    @Test("Missing title and author become flagged placeholders")
    func placeholders() {
        let book = Book(sourceKind: .local, title: "  ", authorRaw: nil)
        #expect(book.title == Placeholders.title)
        #expect(book.titleIsPlaceholder)
        #expect(book.authorRaw == Placeholders.author)
        #expect(book.authorIsPlaceholder)
    }

    @Test("Recently viewed: newest opened first, never-opened last by date added")
    func recentlyViewed() async throws {
        try await save(
            makeBook("old", title: "Old", added: 1, opened: 5),
            makeBook("new", title: "New", added: 1, opened: 9),
            makeBook("never1", title: "Never 1", added: 2),
            makeBook("never2", title: "Never 2", added: 7)
        )
        #expect(try await ids(LibraryQuery(sort: .recentlyViewed)) == ["new", "old", "never2", "never1"])
        #expect(
            try await ids(LibraryQuery(sort: .recentlyViewed, reversed: true)) == ["old", "new", "never1", "never2"]
        )

        try await repositories.books.markOpened(id: "never1", at: day(20))
        #expect(try await ids(LibraryQuery(sort: .recentlyViewed)).first == "never1")
    }

    @Test("Title: articles ignored, placeholders last in both directions")
    func titleSort() async throws {
        try await save(
            makeBook("hobbit", title: "The Hobbit"),
            makeBook("anathem", title: "Anathem"),
            makeBook("unknown", title: nil),
            makeBook("wizard", title: "A Wizard of Earthsea")
        )
        #expect(try await ids(LibraryQuery(sort: .title)) == ["anathem", "hobbit", "wizard", "unknown"])
        #expect(
            try await ids(LibraryQuery(sort: .title, reversed: true)) == ["wizard", "hobbit", "anathem", "unknown"]
        )
    }

    @Test("Author: family name, then given name, then title; placeholders last")
    func authorSort() async throws {
        try await save(
            makeBook("leguin2", title: "The Lathe of Heaven", author: "Ursula K. Le Guin", family: "Le Guin"),
            makeBook("leguin1", title: "Always Coming Home", author: "Ursula K. Le Guin", family: "Le Guin"),
            makeBook("banks", title: "Excession", author: "Iain M. Banks", family: "Banks", given: "Iain M."),
            makeBook("org", title: "Manual", author: "Zeta Press"),
            makeBook("nobody", title: "Anonymous", author: nil)
        )
        #expect(
            try await ids(LibraryQuery(sort: .author)) == ["banks", "leguin1", "leguin2", "org", "nobody"]
        )
    }

    @Test("Publication date: oldest first, undated last in both directions")
    func publicationDateSort() async throws {
        try await save(
            makeBook("y1969", title: "B", year: 1969),
            makeBook("undated", title: "A"),
            makeBook("y2008", title: "C", year: 2008)
        )
        #expect(try await ids(LibraryQuery(sort: .publicationDate)) == ["y1969", "y2008", "undated"])
        #expect(
            try await ids(LibraryQuery(sort: .publicationDate, reversed: true)) == ["y2008", "y1969", "undated"]
        )
    }

    @Test("Downloaded books come first")
    func downloadStateSort() async throws {
        try await save(
            makeBook("remote", title: "A"),
            makeBook("local", title: "B", state: .downloaded),
            makeBook("failed", title: "C", state: .failed)
        )
        #expect(try await ids(LibraryQuery(sort: .downloadState)) == ["local", "remote", "failed"])
    }

    @Test("Search matches word prefixes in title, author, and collection names")
    func search() async throws {
        try await save(
            makeBook("hobbit", title: "The Hobbit", author: "J. R. R. Tolkien"),
            makeBook("earthsea", title: "A Wizard of Earthsea", author: "Ursula K. Le Guin")
        )
        let collection = try await repositories.collections.createCollection(named: "Favourites")
        try await repositories.collections.addBook("earthsea", toCollection: collection.id)

        #expect(try await ids(LibraryQuery(sort: .title, searchText: "hob")) == ["hobbit"])
        #expect(try await ids(LibraryQuery(sort: .title, searchText: "tolk")) == ["hobbit"])
        #expect(try await ids(LibraryQuery(sort: .title, searchText: "favour")) == ["earthsea"])
        #expect(try await ids(LibraryQuery(sort: .title, searchText: "le guin wiz")) == ["earthsea"])
        #expect(try await ids(LibraryQuery(sort: .title, searchText: "   ")).count == 2)
        #expect(try await ids(LibraryQuery(sort: .title, searchText: "\"")) == [])
        #expect(try await ids(LibraryQuery(sort: .title, searchText: "dune")) == [])
    }

    @Test("Observing the library yields the current list, then the list after a change")
    func observeLibrary() async throws {
        try await save(makeBook("first", title: "First"))
        var iterator = repositories.books.observeLibrary(LibraryQuery(sort: .title)).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.id) == ["first"])

        try await save(makeBook("second", title: "Second"))
        #expect(try await iterator.next()?.map(\.id) == ["first", "second"])
    }
}

@Suite("Collection repository")
struct CollectionRepositoryTests {
    let repositories: DatabaseRepositories

    init() throws {
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
    }

    @Test("Names are trimmed, and empty or duplicate names are rejected")
    func names() async throws {
        let collection = try await repositories.collections.createCollection(named: "  To Read ")
        #expect(collection.name == "To Read")
        await #expect(throws: RepositoryError.emptyName) {
            _ = try await repositories.collections.createCollection(named: "   ")
        }
        await #expect(throws: RepositoryError.duplicateName) {
            _ = try await repositories.collections.createCollection(named: "to read")
        }
        let other = try await repositories.collections.createCollection(named: "Other")
        await #expect(throws: RepositoryError.duplicateName) {
            try await repositories.collections.renameCollection(id: other.id, to: "TO READ")
        }
    }

    @Test("New collections go last; reordering sets the order")
    func ordering() async throws {
        let a = try await repositories.collections.createCollection(named: "A")
        let b = try await repositories.collections.createCollection(named: "B")
        let c = try await repositories.collections.createCollection(named: "C")
        var iterator = repositories.collections.observeCollections().makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.name) == ["A", "B", "C"])

        try await repositories.collections.reorderCollections([c.id, a.id, b.id])
        #expect(try await iterator.next()?.map(\.name) == ["C", "A", "B"])
    }

    @Test("Books can be added and removed; deleting a collection keeps its books")
    func membership() async throws {
        try await repositories.books.save(makeBook("b1", title: "Zed"))
        try await repositories.books.save(makeBook("b2", title: "Alpha"))
        let shelf = try await repositories.collections.createCollection(named: "Shelf")

        try await repositories.collections.addBook("b1", toCollection: shelf.id)
        try await repositories.collections.addBook("b2", toCollection: shelf.id)
        try await repositories.collections.addBook("b2", toCollection: shelf.id)  // Adding twice is harmless.
        var iterator = repositories.collections.observeBooks(inCollection: shelf.id).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.id) == ["b2", "b1"])
        #expect(try await repositories.collections.collections(containing: "b1").map(\.id) == [shelf.id])

        try await repositories.collections.removeBook("b1", fromCollection: shelf.id)
        #expect(try await iterator.next()?.map(\.id) == ["b2"])

        try await repositories.collections.deleteCollection(id: shelf.id)
        #expect(try await repositories.collections.collections(containing: "b2").isEmpty)
        #expect(try await repositories.books.book(id: "b2") != nil)
    }
}

@Suite("Series repository")
struct SeriesRepositoryTests {
    let repositories: DatabaseRepositories

    init() throws {
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
    }

    @Test("A book is in at most one series; numbered entries come first in order")
    func entries() async throws {
        for (id, title) in [("one", "Book One"), ("two", "Book Two"), ("half", "Novella"), ("extra", "Extra")] {
            try await repositories.books.save(makeBook(id, title: title))
        }
        let earthsea = try await repositories.series.createSeries(named: "Earthsea")
        let other = try await repositories.series.createSeries(named: "Other")
        await #expect(throws: RepositoryError.duplicateName) {
            _ = try await repositories.series.createSeries(named: "EARTHSEA")
        }

        try await repositories.series.setSeries(earthsea.id, position: 2, forBook: "two")
        try await repositories.series.setSeries(earthsea.id, position: 1, forBook: "one")
        try await repositories.series.setSeries(earthsea.id, position: 1.5, forBook: "half")
        try await repositories.series.setSeries(earthsea.id, position: nil, forBook: "extra")

        var iterator = repositories.series.observeEntries(inSeries: earthsea.id).makeAsyncIterator()
        let entries = try #require(try await iterator.next())
        #expect(entries.map(\.book.id) == ["one", "half", "two", "extra"])
        #expect(entries.map(\.position) == [1, 1.5, 2, nil])

        try await repositories.series.setSeries(other.id, position: 4, forBook: "two")
        let membership = try #require(try await repositories.series.series(containing: "two"))
        #expect(membership.series.id == other.id)
        #expect(membership.position == 4)
        #expect(try await iterator.next()?.map(\.book.id) == ["one", "half", "extra"])

        try await repositories.series.setSeries(nil, position: nil, forBook: "two")
        #expect(try await repositories.series.series(containing: "two") == nil)
    }

    @Test("Deleting a series keeps its books")
    func deleteSeries() async throws {
        try await repositories.books.save(makeBook("b1", title: "Kept"))
        let series = try await repositories.series.createSeries(named: "Gone")
        try await repositories.series.setSeries(series.id, position: 1, forBook: "b1")

        try await repositories.series.deleteSeries(id: series.id)
        #expect(try await repositories.series.series(containing: "b1") == nil)
        #expect(try await repositories.books.book(id: "b1") != nil)
    }
}

@Suite("Bookmark and reading position repositories")
struct ReadingRepositoryTests {
    let repositories: DatabaseRepositories

    init() throws {
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
    }

    @Test("Bookmarks come back in reading order and can be deleted")
    func bookmarks() async throws {
        try await repositories.books.save(makeBook("b1", title: "Book"))
        let late = Bookmark(bookId: "b1", locatorJSON: "{}", progression: 0.8, createdAt: day(1))
        let early = Bookmark(bookId: "b1", locatorJSON: "{}", progression: 0.1, createdAt: day(2))
        try await repositories.bookmarks.addBookmark(late)
        try await repositories.bookmarks.addBookmark(early)

        var iterator = repositories.bookmarks.observeBookmarks(forBook: "b1").makeAsyncIterator()
        #expect(try await iterator.next() == [early, late])

        try await repositories.bookmarks.deleteBookmark(id: early.id)
        #expect(try await iterator.next() == [late])
    }

    @Test("Bookmark progression is clamped and snippets are truncated")
    func bookmarkLimits() {
        let bookmark = Bookmark(
            bookId: "b1",
            locatorJSON: "{}",
            progression: 1.7,
            textSnippet: String(repeating: "x", count: 500)
        )
        #expect(bookmark.progression == 1)
        #expect(bookmark.textSnippet?.count == Bookmark.maxSnippetLength)
    }

    @Test("Saving a position replaces the old one and updates the book's progression")
    func readingPosition() async throws {
        try await repositories.books.save(makeBook("b1", title: "Book"))
        #expect(try await repositories.readingPositions.position(forBook: "b1") == nil)

        let first = ReadingPosition(bookId: "b1", locatorJSON: #"{"p":1}"#, updatedAt: day(1))
        try await repositories.readingPositions.savePosition(first, progression: 0.3)
        let second = ReadingPosition(bookId: "b1", locatorJSON: #"{"p":2}"#, updatedAt: day(2))
        try await repositories.readingPositions.savePosition(second, progression: 1.4)

        #expect(try await repositories.readingPositions.position(forBook: "b1") == second)
        #expect(try await repositories.books.book(id: "b1")?.progression == 1)
    }
}
