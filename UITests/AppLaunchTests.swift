import XCTest

/// Smoke test: the app launches and every tab is reachable.
/// Screenshots are kept so CI can publish them as the `screenshots` artifact.
final class AppLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEachTabOpens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        app.launch()

        for tab in ["Library", "Collections", "Settings"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 15), "Tab \(tab) not found")
            button.tap()
            XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 10), "\(tab) screen did not appear")

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(tab) tab"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
