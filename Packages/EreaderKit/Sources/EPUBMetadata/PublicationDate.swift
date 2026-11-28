/// A `dc:date` value reduced to what the library shows and sorts by.
/// Accepts "YYYY", "YYYY-MM", "YYYY-MM-DD", and full ISO timestamps (the time is ignored).
struct PublicationDate: Equatable, Sendable {
    var year: Int
    var month: Int?
    var day: Int?

    init?(parsing raw: String) {
        let datePart = raw.split(whereSeparator: { $0 == "T" || $0 == " " }).first.map(String.init) ?? ""
        let parts = datePart.split(separator: "-", omittingEmptySubsequences: false)
        let expectedLengths = [4, 2, 2]
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for (part, length) in zip(parts, expectedLengths) {
            let isDigits = part.allSatisfy { $0.isASCII && $0.isNumber }
            guard part.count == length, isDigits, let number = Int(part) else { return nil }
            numbers.append(number)
        }
        // Calibre writes 0101-01-01 when the date is unknown.
        guard numbers[0] > 101 else { return nil }
        year = numbers[0]
        if numbers.count > 1 {
            guard (1...12).contains(numbers[1]) else { return nil }
            month = numbers[1]
        }
        if numbers.count > 2 {
            guard (1...31).contains(numbers[2]) else { return nil }
            day = numbers[2]
        }
    }

    /// "1998", "1998-07", or "1998-07-14".
    var isoString: String {
        var text = String(year)
        if let month { text += "-" + Self.twoDigits(month) }
        if let day { text += "-" + Self.twoDigits(day) }
        return text
    }

    /// `yyyymmdd` with missing parts as 00, so a bare year sorts before dates within it.
    var sortKey: Int {
        year * 10_000 + (month ?? 0) * 100 + (day ?? 0)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }
}
