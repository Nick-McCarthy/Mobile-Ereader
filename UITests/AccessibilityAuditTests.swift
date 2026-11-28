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
        try auditAccessibility(app)
    }

    @MainActor
    func testLibraryWithABookPassesAudit() throws {
        let app = launch(arguments: ["-UITestMode", "-UITestSeedBook"])
        // The row combines its texts into one element, so match on part of its label.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Tombs of Atuan"))
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 15))
        try auditAccessibility(app)
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
