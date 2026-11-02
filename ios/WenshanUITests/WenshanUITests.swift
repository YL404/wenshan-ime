import XCTest

final class WenshanUITests: XCTestCase {
    func testTypeWomf() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        sleep(2)
        addScreenshot("聚焦后")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // 键盘窗口高 270pt，屏幕底部还留系统地球/麦克风行。
        // 按窗口内 frame + 截图校准：q 0.697，a 0.759，z 0.822，空格 0.884。
        let keys: [(CGFloat, CGFloat)] = [
            (0.1567, 0.697), // w
            (0.8433, 0.697), // o
            (0.9200, 0.822), // m
            (0.3910, 0.759), // f
        ]
        for (x, y) in keys {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
            usleep(400_000)
        }
        addScreenshot("输入 womf 后")

        // 空格：有候选时选第一个。
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3777, dy: 0.884)).tap()
        sleep(1)
        addScreenshot("上屏后")

        let value = field.value as? String ?? ""
        XCTAssertTrue(value.contains("我们"), "上屏结果不是“我们”：\(value)")
    }

    private func addScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
