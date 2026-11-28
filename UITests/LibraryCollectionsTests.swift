import XCTest

/// The library's collections view groups books by collection, then "Not in a Collection", and a section's
/// header collapses and expands it (P3.4).
final class LibraryCollectionsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGroupsByCollectionAndCollapses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-UITestSeedBooks"]
        app.launch()
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        XCTAssertTrue(books(app).firstMatch.waitForExistence(timeout: 15))

        app.navigationBars["Library"].buttons["View"].tap()
        // The menu item, not the Collections tab.
        let tabBar = app.tabBars.firstMatch.frame
        let items = app.buttons.matching(NSPredicate(format: "label == %@", "Collections"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5))
        let item = try XCTUnwrap(items.allElementsBoundByIndex.first { !tabBar.intersects($0.frame) })
        item.tap()

        // Collections in the user's order, then the rest. Tombs is in both collections, so it shows twice.
        let leGuin = header(app, "Le Guin, 2 books")
        XCTAssertTrue(leGuin.waitForExistence(timeout: 10), "No Le Guin section")
        XCTAssertTrue(header(app, "Favourites, 1 book").exists)
        XCTAssertTrue(header(app, "Not in a Collection, 2 books").exists)
        let order = [
            "Le Guin, 2 books",
            "Favourites, 1 book",
            "Not in a Collection, 2 books",
        ]
        XCTAssertEqual(headers(app).allElementsBoundByIndex.map(\.label), order)
        XCTAssertEqual(leGuin.value as? String, "Expanded")
        XCTAssertTrue(waitForBookCount(app, 5))
        try auditAccessibility(app)

        leGuin.tap()
        XCTAssertTrue(waitForBookCount(app, 3), "Collapsing Le Guin didn't hide its two books")
        XCTAssertEqual(leGuin.value as? String, "Collapsed")
        leGuin.tap()
        XCTAssertTrue(waitForBookCount(app, 5))
    }

    @MainActor
    private func books(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "library-book")
    }

    @MainActor
    private func headers(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "collection-header")
    }

    @MainActor
    private func header(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        headers(app).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    private func waitForBookCount(_ app: XCUIApplication, _ count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if books(app).count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }
}
