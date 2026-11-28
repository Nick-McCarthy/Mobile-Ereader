import Foundation
import Testing

@testable import EPUBMetadata

@Suite("Untrusted XML")
struct MarkupTests {
    static let entityDocument = """
        <?xml version="1.0" encoding="UTF-16"?>
        <!DOCTYPE p [<!ENTITY a "aaaa"><!ENTITY % b "bbbb">]>
        <package version="3.0">&a;</package>
        """
    static let plainDocument = """
        <?xml version="1.0" encoding="UTF-16"?>
        <package version="3.0"><title>Tehanu</title></package>
        """

    @Test(
        "Entity declarations are refused in UTF-16, which the UTF-8 byte search can't see",
        arguments: [String.Encoding.utf16LittleEndian, .utf16BigEndian]
    )
    func utf16Entities(encoding: String.Encoding) throws {
        let data = try #require(Self.utf16(Self.entityDocument, encoding: encoding))
        #expect(data.range(of: Data("<!ENTITY".utf8)) == nil, "the fixture must slip past the byte search")
        #expect(Markup.parse(data, maxDepth: 32) == nil)
    }

    @Test(
        "A UTF-16 document without entities still parses",
        arguments: [String.Encoding.utf16LittleEndian, .utf16BigEndian]
    )
    func utf16Plain(encoding: String.Encoding) throws {
        let data = try #require(Self.utf16(Self.plainDocument, encoding: encoding))
        let root = try #require(Markup.parse(data, maxDepth: 32))
        #expect(root.descendants(named: "title").first?.text == "Tehanu")
    }

    /// The text with a byte-order mark, as a UTF-16 file on disk would have.
    static func utf16(_ text: String, encoding: String.Encoding) -> Data? {
        let bom: [UInt8] = encoding == .utf16BigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]
        guard let body = text.data(using: encoding) else { return nil }
        return Data(bom) + body
    }
}
