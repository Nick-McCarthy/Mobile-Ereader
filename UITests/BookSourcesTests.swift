import XCTest

/// Settings › Book Sources (action plan P2.8): the service rows, and a linked iCloud folder's detail screen
/// with sync and unlink. `-UITestLinkedFolder` links an empty temporary folder at launch, because the system
/// folder picker can't be driven from a UI test.
final class BookSourcesTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsListsEveryServiceAndPassesAudit() throws {
        let app = launchInSettings(arguments: ["-UITestMode"])
        XCTAssertTrue(element(app, containing: "iCloud Drive / Files").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, containing: "Not linked").exists)
        XCTAssertTrue(element(app, containing: "Dropbox").exists)
        XCTAssertTrue(element(app, containing: "OneDrive").exists)
        XCTAssertTrue(element(app, containing: "Coming in a later version").exists)
        XCTAssertFalse(app.buttons["Sync Now"].exists, "nothing is linked, so there is nothing to sync")
        try auditAccessibility(app)
    }

    @MainActor
    func testLinkedFolderSyncsAndUnlinks() throws {
        let app = launchInSettings(arguments: ["-UITestMode", "-UITestLinkedFolder"])
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UITest Books")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        app.buttons["Sync This Source"].tap()
        XCTAssertTrue(app.staticTexts["Books Found"].waitForExistence(timeout: 30))
        try auditAccessibility(app)

        app.buttons["Unlink…"].tap()
        XCTAssertTrue(element(app, containing: "won't be changed").waitForExistence(timeout: 10))
        app.buttons["Unlink"].tap()

        // Back in Settings, with the folder gone.
        XCTAssertTrue(element(app, containing: "Not linked").waitForExistence(timeout: 15))
        XCTAssertFalse(row.exists)
    }

    @MainActor
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func launchInSettings(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        return app
    }
}
