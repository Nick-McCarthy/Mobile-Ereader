import XCTest

/// The library's search field filters as you type: an author in either name order, and a "No Results" screen when
/// nothing matches (P3.3).
final class LibrarySearchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchFiltersAndShowsNoResults() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-UITestSeedBooks"]
        app.launch()
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        XCTAssertTrue(books(app).firstMatch.waitForExistence(timeout: 15))

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No search field")
        field.tap()
        // One book stores "Ursula K. Le Guin", the other "Le Guin, Ursula K."; both orders find both.
        field.typeText("ursula le")
        expectTitles(app, ["The Left Hand of Darkness", "The Tombs of Atuan"])
        clear(field)
        field.typeText("le guin, urs")
        expectTitles(app, ["The Left Hand of Darkness", "The Tombs of Atuan"])

        clear(field)
        field.typeText("zzzz\n")
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 10))
        try auditAccessibility(app)

        clear(field)
        expectTitles(app, ["Anathem", "The Left Hand of Darkness", "The Tombs of Atuan", "Unknown Title"])
    }

    @MainActor
    private func books(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "library-book")
    }

    @MainActor
    private func clear(_ field: XCUIElement) {
        field.tap()
        let text = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }

    /// Waits for the library to show exactly these books, in any order (the search updates after a short pause).
    @MainActor
    private func expectTitles(
        _ app: XCUIApplication,
        _ titles: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var shown: Set<String> = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            shown = Set(books(app).allElementsBoundByIndex.map { $0.label.components(separatedBy: ", ").first ?? "" })
            if shown == titles { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        XCTFail("Library shows \(shown.sorted()), expected \(titles.sorted())", file: file, line: line)
    }
}
