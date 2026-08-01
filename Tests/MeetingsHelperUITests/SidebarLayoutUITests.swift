import XCTest

final class SidebarLayoutUITests: XCTestCase {
    private let minimumToolbarGap: CGFloat = 8

    func testSidebarContentRemainsBelowToolbarWhenRecordingStarts() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-sidebar-recording-transition"]
        app.launch()

        let toolbar = app.toolbars.firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5), "The main window toolbar did not appear")

        let meetingsHeader = app.staticTexts["sidebar-meetings-header"]
        XCTAssertTrue(meetingsHeader.waitForExistence(timeout: 5), "The Meetings section did not appear")
        assertBelowToolbar(meetingsHeader, toolbar: toolbar)

        let nowHeader = app.staticTexts["sidebar-now-header"]
        XCTAssertTrue(nowHeader.waitForExistence(timeout: 5), "The recording section did not appear")
        assertBelowToolbar(nowHeader, toolbar: toolbar)
        assertBelowToolbar(meetingsHeader, toolbar: toolbar)
    }

    private func assertBelowToolbar(
        _ element: XCUIElement,
        toolbar: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            element.frame.minY,
            toolbar.frame.maxY + minimumToolbarGap,
            "\(element.identifier) is not fully separated from the toolbar; "
                + "element frame: \(element.frame), toolbar frame: \(toolbar.frame)",
            file: file,
            line: line
        )
    }
}
