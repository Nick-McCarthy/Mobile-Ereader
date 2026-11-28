import Foundation

/// A minimal XML tree. Names and attribute keys have their namespace prefix removed ("dc:title" → "title"),
/// which is how EPUBs are read in practice: prefixes vary between books but the local names don't.
struct MarkupElement: Sendable {
    var name: String
    var attributes: [String: String] = [:]
    var children: [MarkupElement] = []
    var text = ""

    subscript(attribute: String) -> String? {
        attributes[attribute]
    }

    var trimmedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func children(named name: String) -> [MarkupElement] {
        children.filter { $0.name == name }
    }

    func firstChild(named name: String) -> MarkupElement? {
        children.first { $0.name == name }
    }

    /// Every element below this one with the given name, in document order.
    func descendants(named name: String) -> [MarkupElement] {
        var found: [MarkupElement] = []
        for child in children {
            if child.name == name { found.append(child) }
            found.append(contentsOf: child.descendants(named: name))
        }
        return found
    }
}

enum Markup {
    /// Parses untrusted XML. External entities are never resolved, entity declarations are refused outright
    /// (package documents never need them, and they enable expansion attacks), and nesting is capped.
    static func parse(_ data: Data, maxDepth: Int) -> MarkupElement? {
        guard data.range(of: Data("<!ENTITY".utf8)) == nil else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        let builder = TreeBuilder(maxDepth: maxDepth)
        parser.delegate = builder
        guard parser.parse(), !builder.exceededDepth, builder.stack.count == 1 else { return nil }
        return builder.stack.first
    }

    static func localName(_ qualifiedName: String) -> String {
        guard let colon = qualifiedName.lastIndex(of: ":") else { return qualifiedName }
        return String(qualifiedName[qualifiedName.index(after: colon)...])
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var stack = [MarkupElement(name: "#document")]
    var exceededDepth = false
    private let maxDepth: Int

    init(maxDepth: Int) {
        self.maxDepth = maxDepth
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard stack.count <= maxDepth else {
            exceededDepth = true
            parser.abortParsing()
            return
        }
        let attributes = Dictionary(
            attributeDict.map { (Markup.localName($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        stack.append(MarkupElement(name: Markup.localName(elementName), attributes: attributes))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard stack.count > 1, let element = stack.popLast() else { return }
        stack[stack.count - 1].children.append(element)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        stack[stack.count - 1].text += String(decoding: block, as: UTF8.self)
    }
}
