/// The collections and which books are in each (`CollectionRepository.observeMemberships()`).
public struct CollectionMemberships: Equatable, Sendable {
    /// In the user's order.
    public var collections: [BookCollection]
    public var bookIds: [BookCollection.ID: Set<Book.ID>]

    public init(collections: [BookCollection] = [], bookIds: [BookCollection.ID: Set<Book.ID>] = [:]) {
        self.collections = collections
        self.bookIds = bookIds
    }
}

/// One section of the library's collections view: a collection, or the books in none (P3.4,
/// docs/UI_SPEC.md#library).
public struct LibrarySection: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case collection(BookCollection)
        case notInACollection
    }

    /// Stable across launches, for remembering which sections are collapsed.
    public static let notInACollectionId = "not-in-a-collection"

    public var kind: Kind
    /// In the library's sort order.
    public var books: [Book]

    public var id: String {
        switch kind {
        case .collection(let collection): collection.id
        case .notInACollection: Self.notInACollectionId
        }
    }

    /// Groups `books`, already sorted and searched, by collection: one section per collection in the user's
    /// order, then the books in no collection. A book in several collections appears in each. Sections with no
    /// books (an empty collection, or none matching the search) are left out.
    public static func byCollection(_ books: [Book], memberships: CollectionMemberships) -> [LibrarySection] {
        var sections: [LibrarySection] = []
        var inSome: Set<Book.ID> = []
        for collection in memberships.collections {
            let ids = memberships.bookIds[collection.id] ?? []
            let members = books.filter { ids.contains($0.id) }
            inSome.formUnion(ids)
            if !members.isEmpty { sections.append(LibrarySection(kind: .collection(collection), books: members)) }
        }
        let rest = books.filter { !inSome.contains($0.id) }
        if !rest.isEmpty { sections.append(LibrarySection(kind: .notInACollection, books: rest)) }
        return sections
    }
}
