import XCTest

/// Runs Xcode's accessibility audit (labels, contrast, hit areas, Dynamic Type, …) on the Library, empty
/// and with a book (finding F-F1). A failure names the element and the issue.
final class AccessibilityAuditTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyLibraryPassesAudit() throws {
        let app = launch(arguments: ["-UITestMode"])
        XCTAssertTrue(app.staticTexts["No Books Yet"].waitForExistence(timeout: 15))
        try audit(app)
    }

    @MainActor
    func testLibraryWithABookPassesAudit() throws {
        let app = launch(arguments: ["-UITestMode", "-UITestSeedBook"])
        // The row combines its texts into one element, so match on part of its label.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Tombs of Atuan"))
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 15))
        try audit(app)
    }

    /// Runs the audit and names each failing element in the test log, so CI output says what to fix.
    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit { issue in
            let element = issue.element.map { "\($0.elementType.rawValue) \"\($0.label)\" \($0.frame)" } ?? "no element"
            // Reported here, with the element, instead of the audit's own message, which doesn't name it.
            XCTFail("\(issue.compactDescription) on \(element): \(issue.detailedDescription)")
            return true
        }
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        return app
    }
}
