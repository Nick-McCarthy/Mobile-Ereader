import XCTest

/// The *Sort* menu reorders the library, in both directions, with books that have no value kept last (P3.2).
final class LibrarySortTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSortByTitleBothWays() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-UITestSeedBooks"]
        app.launch()
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        XCTAssertTrue(books(app).firstMatch.waitForExistence(timeout: 15))

        choose(app, "Title")
        // "The" is ignored, and the placeholder title stays last.
        expectOrder(app, ["Anathem", "The Left Hand of Darkness", "The Tombs of Atuan", "Unknown Title"])

        choose(app, "Z to A")
        expectOrder(app, ["The Tombs of Atuan", "The Left Hand of Darkness", "Anathem", "Unknown Title"])
        try auditAccessibility(app)
    }

    @MainActor
    private func books(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "library-book")
    }

    @MainActor
    private func choose(_ app: XCUIApplication, _ item: String) {
        app.navigationBars["Library"].buttons["Sort"].tap()
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(item) isn't in the Sort menu")
        button.tap()
    }

    /// Waits for the library to show the books in this order (it updates when the observation restarts).
    @MainActor
    private func expectOrder(
        _ app: XCUIApplication,
        _ titles: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var shown: [String] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            shown = books(app).allElementsBoundByIndex.map { $0.label.components(separatedBy: ", ").first ?? "" }
            if shown == titles { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        XCTFail("Library order is \(shown), expected \(titles)", file: file, line: line)
    }
}
