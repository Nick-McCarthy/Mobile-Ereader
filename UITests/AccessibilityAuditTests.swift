import XCTest

/// Runs Xcode's accessibility audit (labels, contrast, hit areas, Dynamic Type, …) on the Library: empty, and
/// with books in each download state in the grid and the list (findings F-F1, P3.1). A failure names the
/// element and the issue.
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
    func testLibraryGridPassesAudit() throws {
        let app = launch(arguments: ["-UITestMode", "-UITestSeedBooks"])
        // Each cell is one element: "Title, Author", with the download state and progress as its value.
        let tombs = book(app, "The Tombs of Atuan")
        XCTAssertTrue(tombs.waitForExistence(timeout: 15))
        XCTAssertEqual(tombs.value as? String, "Downloaded, 42% read, Published 1971")
        XCTAssertEqual(book(app, "Unknown Title").value as? String, "Not downloaded")
        XCTAssertEqual(book(app, "The Left Hand of Darkness").value as? String, "Download failed")
        XCTAssertEqual(book(app, "Anathem").value as? String, "Missing from source")
        attachScreenshot(app, named: "Library grid")
        try auditAccessibility(app)
    }

    @MainActor
    func testLibraryListPassesAudit() throws {
        let app = launch(arguments: ["-UITestMode", "-UITestSeedBooks"])
        XCTAssertTrue(book(app, "The Tombs of Atuan").waitForExistence(timeout: 15))
        app.navigationBars["Library"].buttons["View"].tap()
        let list = app.buttons["List"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.tap()

        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10), "The list didn't appear")
        let tombs = book(app, "The Tombs of Atuan")
        XCTAssertTrue(tombs.waitForExistence(timeout: 10))
        XCTAssertEqual(tombs.value as? String, "Downloaded, 42% read, Published 1971")
        attachScreenshot(app, named: "Library list")
        try auditAccessibility(app)
    }

    /// The cell or row of the book with this title.
    @MainActor
    private func book(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).firstMatch
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
