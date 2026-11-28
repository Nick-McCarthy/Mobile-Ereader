import Foundation

/// One person's name split into parts. See docs/EPUB_METADATA.md#author-name-normalisation.
public struct PersonName: Equatable, Sendable {
    /// Given names and initials ("Ursula K."), or nil for single names such as "Homer".
    public var given: String?
    /// Family name including particles ("Le Guin", "van der Berg"). Used for sorting.
    public var family: String
    /// "Jr.", "III", "PhD", …
    public var suffix: String?

    public init(given: String? = nil, family: String, suffix: String? = nil) {
        self.given = given
        self.family = family
        self.suffix = suffix
    }

    /// "Ursula K. Le Guin", "Martin Luther King Jr."
    public var firstLast: String {
        [given, family, suffix].compactMap { $0 }.joined(separator: " ")
    }

    /// "Le Guin, Ursula K.", "King, Martin Luther, Jr.", "Homer"
    public var lastFirst: String {
        [family, given, suffix].compactMap { $0 }.joined(separator: ", ")
    }
}

/// An author field (possibly several people) with its stored format and parsed parts.
public struct AuthorName: Equatable, Sendable {
    public var raw: String
    public var storedFormat: AuthorStoredFormat
    /// The people named, in order. Empty when the format is `unknown` (organisations, unparseable values).
    public var people: [PersonName]

    /// The person the library sorts by.
    public var primary: PersonName? { people.first }

    /// Detects the stored format, then parses. `fileAs` is the book's `file-as` value, if any.
    public init(raw: String, fileAs: String? = nil) {
        let format = AuthorNameParser.detectFormat(raw)
        self.init(raw: raw, storedFormat: format, fileAs: fileAs)
    }

    /// Parses `raw` as `storedFormat` (detected earlier, or chosen by the user in Edit Details).
    public init(raw: String, storedFormat: AuthorStoredFormat, fileAs: String? = nil) {
        self.raw = raw
        self.storedFormat = storedFormat
        self.people = AuthorNameParser.people(in: raw, format: storedFormat, fileAs: fileAs)
    }
}

/// The Settings → Library → Author name format choice. Stored in UserDefaults by raw value.
public enum AuthorDisplayFormat: String, CaseIterable, Codable, Sendable {
    /// Exactly as the book (or the user) wrote it.
    case asStored
    case firstLast
    case lastFirst
}

/// Renders an author field in the user's chosen format. Pure, so it is safe to call from any view.
public enum AuthorNameFormatter {
    public static func string(for name: AuthorName, in format: AuthorDisplayFormat) -> String {
        guard name.storedFormat != .unknown, !name.people.isEmpty else { return name.raw }
        switch format {
        case .asStored:
            return name.raw
        case .firstLast:
            return name.people.map(\.firstLast).joined(separator: " & ")
        case .lastFirst:
            return name.people.map(\.lastFirst).joined(separator: " & ")
        }
    }

    public static func string(
        raw: String,
        storedFormat: AuthorStoredFormat,
        fileAs: String? = nil,
        in format: AuthorDisplayFormat
    ) -> String {
        string(for: AuthorName(raw: raw, storedFormat: storedFormat, fileAs: fileAs), in: format)
    }
}

/// The heuristics behind `AuthorName`.
enum AuthorNameParser {
    /// Matched case-insensitively with dots removed.
    static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "phd", "md", "esq"]
    /// Lower-case words kept with the family name: "Le Guin", "van der Berg", "de la Cruz".
    static let particles: Set<String> = [
        "van", "von", "de", "da", "di", "du", "del", "della", "der", "den", "des", "la", "le", "ter", "ten",
        "dos", "das", "st.",
    ]
    /// Words that mark an organisation rather than a person.
    static let organisationWords: Set<String> = [
        "press", "publishing", "publishers", "books", "inc", "inc.", "ltd", "ltd.", "llc", "company", "co.",
        "society", "association", "institute", "university", "foundation", "committee", "staff", "group",
        "editors", "team", "project", "gutenberg",
    ]

    /// Splits several authors joined with "&" or ";".
    static func parts(of raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "&" || $0 == ";" }).map { normalisedSpaces($0) }.filter { !$0.isEmpty }
    }

    static func detectFormat(_ raw: String) -> AuthorStoredFormat {
        let names = parts(of: raw)
        guard let first = names.first, !names.contains(where: { isOrganisation($0) }) else { return .unknown }
        let commaParts = first.split(separator: ",", omittingEmptySubsequences: false).map { normalisedSpaces($0) }
        switch commaParts.count {
        case 1:
            return .firstLast
        case 2 where isSuffix(commaParts[1]):
            return .firstLast  // "Martin Luther King, Jr."
        case 2 where !commaParts[0].isEmpty && !commaParts[1].isEmpty:
            return .lastFirst  // "Le Guin, Ursula K."
        case 3 where isSuffix(commaParts[2]) && !commaParts[0].isEmpty && !commaParts[1].isEmpty:
            return .lastFirst  // "King, Martin Luther, Jr."
        default:
            return .unknown
        }
    }

    static func people(in raw: String, format: AuthorStoredFormat, fileAs: String?) -> [PersonName] {
        guard format != .unknown else { return [] }
        let names = parts(of: raw)
        // A single person's file-as ("Le Guin, Ursula K.") beats the guess for a "First Last" name.
        if format == .firstLast, names.count == 1, let fileAs, normalisedSpaces(fileAs) != names[0],
            detectFormat(fileAs) == .lastFirst, let person = lastFirst(normalisedSpaces(fileAs))
        {
            return [person]
        }
        return names.compactMap { part in
            // A part without a comma can't be "Last, First", whatever the book-level format says.
            if format == .lastFirst, part.contains(","), let person = lastFirst(part) {
                return person
            }
            return firstLast(part)
        }
    }

    /// "Le Guin, Ursula K." or "King, Martin Luther, Jr."
    static func lastFirst(_ part: String) -> PersonName? {
        let pieces = part.split(separator: ",").map { normalisedSpaces($0) }.filter { !$0.isEmpty }
        guard let family = pieces.first else { return nil }
        let given = pieces.count > 1 ? pieces[1] : nil
        let suffix = pieces.count > 2 ? pieces[2...].joined(separator: ", ") : nil
        return PersonName(given: given, family: family, suffix: suffix)
    }

    /// "Ursula K. Le Guin", "Martin Luther King, Jr.", "Homer"
    static func firstLast(_ part: String) -> PersonName? {
        var words = part.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        var suffix: String?
        if words.count > 1, let last = words.last, isSuffix(last) {
            suffix = last
            words.removeLast()
        }
        guard let lastWord = words.popLast() else { return nil }
        var family = [lastWord]
        // Keep at least one given name: "Van Morrison" is given "Van", family "Morrison".
        while words.count > 1, let previous = words.last, particles.contains(previous.lowercased()) {
            family.insert(previous, at: 0)
            words.removeLast()
        }
        let given = words.isEmpty ? nil : words.joined(separator: " ")
        return PersonName(given: given, family: family.joined(separator: " "), suffix: suffix)
    }

    static func isSuffix(_ word: String) -> Bool {
        suffixes.contains(word.lowercased().replacingOccurrences(of: ".", with: ""))
    }

    static func isOrganisation(_ part: String) -> Bool {
        part.lowercased().split(separator: " ").contains { organisationWords.contains(String($0)) }
    }

    static func normalisedSpaces<S: StringProtocol>(_ text: S) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
