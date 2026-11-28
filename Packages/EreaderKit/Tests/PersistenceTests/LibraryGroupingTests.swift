import Core
import Foundation
import Persistence
import Testing

@Suite("Library grouping by collection")
struct LibraryGroupingTests {
    private func book(_ id: String) -> Book {
        Book(id: id, sourceKind: .local, title: id, authorRaw: "Someone")
    }

    private let shelf = BookCollection(id: "shelf", name: "Shelf", sortOrder: 0)
    private let empty = BookCollection(id: "empty", name: "Empty", sortOrder: 1)
    private let favourites = BookCollection(id: "fav", name: "Favourites", sortOrder: 2)

    private func ids(_ sections: [LibrarySection]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.books.map(\.id)) })
    }

    @Test("Sections follow the collection order, keep the book order, and end with books in no collection")
    func grouping() {
        let books = ["c", "a", "b", "d"].map(book)
        let memberships = CollectionMemberships(
            collections: [shelf, empty, favourites],
            bookIds: ["shelf": ["a", "c"], "fav": ["c"]]
        )
        let sections = LibrarySection.byCollection(books, memberships: memberships)

        #expect(sections.map(\.id) == ["shelf", "fav", LibrarySection.notInACollectionId])
        #expect(ids(sections) == ["shelf": ["c", "a"], "fav": ["c"], LibrarySection.notInACollectionId: ["b", "d"]])
        #expect(sections.first?.kind == .collection(shelf))
        #expect(sections.last?.kind == .notInACollection)
    }

    @Test("Searched-out books leave their sections, and sections left empty go")
    func searched() {
        let memberships = CollectionMemberships(
            collections: [shelf, favourites],
            bookIds: ["shelf": ["a"], "fav": ["c"]]
        )
        let sections = LibrarySection.byCollection([book("c")], memberships: memberships)
        #expect(sections.map(\.id) == ["fav"])
        #expect(LibrarySection.byCollection([], memberships: memberships).isEmpty)
    }

    @Test("With no collections, every book is in the last section")
    func noCollections() {
        let sections = LibrarySection.byCollection(["a", "b"].map(book), memberships: CollectionMemberships())
        #expect(sections.map(\.id) == [LibrarySection.notInACollectionId])
        #expect(sections.first?.books.map(\.id) == ["a", "b"])
    }
}

@Suite("Collection memberships")
struct CollectionMembershipsTests {
    let repositories: DatabaseRepositories

    init() throws {
        repositories = DatabaseRepositories(database: try AppDatabase.inMemory())
    }

    @Test("Memberships list the collections in order with their books, and update after a change")
    func observe() async throws {
        for id in ["a", "b"] {
            try await repositories.books.save(Book(id: id, sourceKind: .local, title: id, authorRaw: "Someone"))
        }
        let second = try await repositories.collections.createCollection(named: "Second")
        let first = try await repositories.collections.createCollection(named: "First")
        try await repositories.collections.reorderCollections([first.id, second.id])
        try await repositories.collections.addBook("a", toCollection: first.id)
        try await repositories.collections.addBook("b", toCollection: first.id)

        var iterator = repositories.collections.observeMemberships().makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.collections.map(\.name) == ["First", "Second"])
        #expect(initial.bookIds == [first.id: ["a", "b"]])

        try await repositories.collections.addBook("a", toCollection: second.id)
        let updated = try #require(try await iterator.next())
        #expect(updated.bookIds == [first.id: ["a", "b"], second.id: ["a"]])

        try await repositories.books.deleteBook(id: "a")
        let afterDelete = try #require(try await iterator.next())
        #expect(afterDelete.bookIds == [first.id: ["b"]])
    }
}
