import XCTest

final class IPadUITests: XCTestCase {
    @MainActor
    func testGridInspectorSelectionAndPanoramaWorkflow() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertFalse(app.buttons["panorama-tool"].exists)
        app.buttons["toggle-sidebar"].tap()
        XCTAssertTrue(app.buttons["All photographs"].waitForExistence(timeout: 5))
        app.buttons["toggle-sidebar"].tap()
        XCTAssertFalse(app.buttons["All photographs"].exists)
        let width = first.frame.width
        app.scrollViews["photo-grid"].pinch(withScale: width < 230 ? 1.5 : 0.65, velocity: width < 230 ? 1 : -1)
        XCTAssertGreaterThan(abs(first.frame.width - width), width * 0.1)

        first.tap()
        XCTAssertTrue(app.otherElements["RGB histogram"].waitForExistence(timeout: 30))
        first.tap()
        XCTAssertFalse(app.otherElements["RGB histogram"].exists)
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["finish-selection"].waitForExistence(timeout: 5))
        app.buttons["photo-Sample-02.tiff"].tap()
        XCTAssertTrue(app.buttons["panorama-tool"].waitForExistence(timeout: 5))
        app.buttons["panorama-tool"].tap()
        XCTAssertTrue(app.buttons["choose-panorama-shift"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["panorama-preview"].exists)
        app.buttons["choose-panorama-shift"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["panorama-preview"].waitForExistence(timeout: 90), app.debugDescription)
        let frame = app.descendants(matching: .any)["shift-frame-0"]
        XCTAssertTrue(frame.exists, app.debugDescription)
        let value = frame.value as? String
        let start = frame.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 10, dy: -8)))
        XCTAssertNotEqual(frame.value as? String, value)
        XCTAssertFalse(app.buttons["panorama-export"].isEnabled)
        // Restore automatic matching after checking drag state; arbitrary offsets need not fit the images.
        let controls = app.scrollViews["panorama-controls"]
        controls.swipeUp()
        app.switches["position-guidance"].tap()
        app.buttons["align-panorama"].tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["panorama-export"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed)
        let workspace = XCTAttachment(screenshot: app.screenshot()); workspace.name = "Large panorama workspace"; workspace.lifetime = .keepAlways; add(workspace)
        app.buttons["panorama-export"].tap()
        app.buttons["confirm-export"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Saved ")).firstMatch.waitForExistence(timeout: 90), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "iPad panorama workspace"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["General"].waitForExistence(timeout: 5))
        app.buttons["Photo library"].firstMatch.tap()
        XCTAssertTrue(app.switches["Skip duplicate imports"].waitForExistence(timeout: 5))
        app.buttons["Lens profiles"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Import lens profile"].waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "Full-screen settings tabs"; settings.lifetime = .keepAlways; add(settings)
        app.buttons["close-settings"].tap()
        app.buttons["grid-view"].tap()
        app.buttons["panorama-tool"].tap()
        app.buttons["choose-panorama-perspective"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["panorama-preview"].waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["body-shift-diagram"].exists)
        XCTAssertTrue(app.navigationBars["Perspective panorama"].exists)
        app.buttons["close-panorama"].tap()
    }
}
