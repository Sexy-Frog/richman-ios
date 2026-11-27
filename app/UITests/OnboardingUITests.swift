import XCTest

/// Walks the first-run flow the way a person does. This exists because the
/// onboarding is bypassed by every other automated test (`-rm.skipOnboarding`).
final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-rm.demo", "1"]
        app.launch()
    }

    func testIntroNextAdvancesAndOnboardingCompletes() {
        XCTAssertTrue(
            text("RichMan へようこそ").waitForExistence(timeout: 15),
            "intro did not appear"
        )

        // Page 1 -> 2
        app.buttons["introNext"].tap()
        let page2 = text("会話は端末間で暗号化")
        if !page2.waitForExistence(timeout: 5) {
            print("=== UI TREE AFTER 次へ ===")
            print(app.debugDescription)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("next did not advance to page 2")
        }

        // Page 2 -> 3
        button("次へ").tap()
        XCTAssertTrue(
            text("追跡しません").waitForExistence(timeout: 5),
            "next did not advance to page 3"
        )

        // Page 3 -> 4
        button("次へ").tap()
        XCTAssertTrue(
            text("プライバシーゾーン").waitForExistence(timeout: 5),
            "next did not advance to page 4"
        )

        // Page 4 -> name step
        button("さあ始めよう").tap()
        XCTAssertTrue(
            text("表示名を決めましょう").waitForExistence(timeout: 5),
            "start did not open the name step"
        )

        // Name -> zone step
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("テスト")
        button("次へ").tap()
        XCTAssertTrue(
            text("プライバシーゾーン").waitForExistence(timeout: 5),
            "name did not advance to the zone step"
        )

        // Zone (later) -> PIN step
        button("後で設定する").tap()
        XCTAssertTrue(
            text("暗証番号を設定").waitForExistence(timeout: 5),
            "zone step did not advance to the PIN step"
        )

        // Terms are required before the keypad works.
        let toggle = app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()

        enterPIN()
        // Confirmation round.
        enterPIN(confirm: true)

        // Hub is only reachable after onboarded flips.
        XCTAssertTrue(
            app.tabBars.buttons["トーク"].waitForExistence(timeout: 10),
            "onboarding never completed"
        )
    }

    private func enterPIN(confirm: Bool = false) {
        for digit in ["1", "2", "3", "4"] {
            let key = app.buttons[digit]
            XCTAssertTrue(key.waitForExistence(timeout: 5))
            key.tap()
        }
    }

    private func text(_ value: String) -> XCUIElement {
        app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", value)
        ).firstMatch
    }

    private func button(_ label: String) -> XCUIElement {
        let element = app.buttons[label]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing button: \(label)")
        return element
    }
}
