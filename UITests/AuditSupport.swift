import XCTest

extension XCTestCase {
    /// Runs Xcode's accessibility audit and reports every issue at once, each with its element, so one CI run
    /// says everything there is to fix (finding F-F1). Reporting from inside the handler would stop at the
    /// first issue when `continueAfterFailure` is false.
    @MainActor
    func auditAccessibility(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        var issues: [String] = []
        try app.performAccessibilityAudit { issue in
            if Self.isKnownSystemIssue(issue) { return true }
            let element = issue.element.map { "\($0.elementType.rawValue) \"\($0.label)\" \($0.frame)" } ?? "no element"
            issues.append("\(issue.compactDescription) on \(element): \(issue.detailedDescription)")
            return true
        }
        if !issues.isEmpty {
            // One line: xcbeautify shows only the first line of a failure message.
            let report = "\(issues.count) accessibility issue(s): " + issues.joined(separator: " | ")
            XCTFail(report, file: file, line: line)
        }
    }

    /// Issues in UIKit's own search field that the app can't change: its clear button (×) is 20 pt, under the
    /// audit's minimum hit area, and its fixed-height text field is reported as clipping at large Dynamic Type
    /// sizes. Each exclusion is listed in docs/UI_SPEC.md#all-screens.
    @MainActor
    private static func isKnownSystemIssue(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        switch issue.auditType {
        case .hitRegion: issue.element?.label == "Clear text"
        case .textClipped: issue.element?.elementType == .searchField
        default: false
        }
    }
}
