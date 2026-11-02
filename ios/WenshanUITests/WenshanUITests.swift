import XCTest

final class WenshanUITests: XCTestCase {
    func testHostDeploysDictionary() throws {
        let app = XCUIApplication()
        app.launch()

        let deployed = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "已部署")).firstMatch
        XCTAssertTrue(deployed.waitForExistence(timeout: 10), "词表没有部署到 App Group")

        let shared = app.staticTexts["已连接 App Group"]
        XCTAssertTrue(shared.waitForExistence(timeout: 5), "宿主看不到 App Group")

        app.swipeUp()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "找不到测试输入框")
        field.tap()
        XCTAssertTrue(field.exists)
    }
}
