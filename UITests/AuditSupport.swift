import XCTest

extension XCTestCase {
    /// Runs Xcode's accessibility audit and names each failing element in the test log, so CI output says
    /// what to fix (finding F-F1).
    @MainActor
    func auditAccessibility(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit { issue in
            let element = issue.element.map { "\($0.elementType.rawValue) \"\($0.label)\" \($0.frame)" } ?? "no element"
            // Reported here, with the element, instead of the audit's own message, which doesn't name it.
            XCTFail("\(issue.compactDescription) on \(element): \(issue.detailedDescription)")
            return true
        }
    }
}
