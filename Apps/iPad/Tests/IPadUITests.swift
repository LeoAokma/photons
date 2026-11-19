import XCTest

final class IPadUITests: XCTestCase {
    @MainActor
    func testAllGuidesSupportSwipingWithoutChangingPhotosOrPanorama() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo","--test-onboarding"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"
        app.launchEnvironment["PHOTONS_GUIDE_TEST_BUILD"] = "swipe-" + UUID().uuidString
        app.launch(); XCUIDevice.shared.orientation = .landscapeLeft
        let title = app.staticTexts["guide-step-title"]
        func checkPages(_ first: String,_ second: String) {
            XCTAssertTrue(title.waitForExistence(timeout: 10)); XCTAssertEqual(title.label,first)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Swipe guide: \(first)"; shot.lifetime = .keepAlways; add(shot)
            func swipe(_ dx: CGFloat,_ dy: CGFloat = 0) {
                // Use actual screen coordinates: XCTest's ScrollView.swipe can incorrectly
                // clip a landscape callout in the right-hand inspector to portrait width.
                let frame = app.scrollViews["guide-step-detail"].frame
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: frame.midX-dx/2,dy: frame.midY-dy/2))
                let end = origin.withOffset(CGVector(dx: frame.midX+dx/2,dy: frame.midY+dy/2))
                start.press(forDuration: 0.05,thenDragTo: end)
            }
            swipe(140); XCTAssertEqual(title.label,first,"First page must not wrap")
            swipe(-140); XCTAssertEqual(title.label,second)
            swipe(0,-80); XCTAssertEqual(title.label,second,"Vertical reading scroll must not turn the page")
            swipe(140); XCTAssertEqual(title.label,first)
            app.buttons["guide-next"].tap(); XCTAssertEqual(title.label,second,"Buttons remain available")
            app.buttons["guide-close"].tap()
        }
        checkPages("Welcome to Photons","Bring in your photos")
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60))
        app.buttons["workspace-guide"].tap(); checkPages("Browse and select photos","Library and folders")
        XCTAssertEqual(first.value as? String,"Not selected")
        first.doubleTap(); XCTAssertTrue(app.otherElements["photo-canvas-container"].waitForExistence(timeout: 10))
        app.buttons["workspace-guide"].tap(); checkPages("View one photo","Choose a zoom level")
        XCTAssertEqual(app.staticTexts["current-photo-name"].label,"Sample-01.tiff","Guide swipes must not navigate the underlying photo")
        app.buttons["grid-view"].tap(); XCTAssertEqual(first.value as? String,"Selected")
        first.press(forDuration: 0.7); app.buttons["photo-Sample-02.tiff"].tap()
        app.buttons["panorama-tool"].tap(); app.buttons["choose-panorama-shift"].tap()
        let export = app.buttons["panorama-export"]
        XCTAssertTrue(export.wait(for: \.isEnabled,toEqual: true,timeout: 60))
        app.buttons["panorama-guide"].tap(); checkPages("Panorama preview","Histogram")
        XCTAssertTrue(export.isEnabled); app.buttons["close-panorama"].tap()
    }
    @MainActor
    func testQuickStartAppearsOnceForEachBuildAndHelpCanReplay() throws {
        continueAfterFailure = false
        let token = UUID().uuidString
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo","--test-onboarding"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"
        app.launchEnvironment["PHOTONS_GUIDE_TEST_BUILD"] = token + "-A"; app.launch()
        XCTAssertTrue(app.staticTexts["guide-step-title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["guide-step-title"].label,"Welcome to Photons")
        for _ in 0..<4 { app.buttons["guide-next"].tap() }
        XCTAssertEqual(app.staticTexts["guide-step-title"].label,"Help is always nearby")
        app.buttons["guide-close"].tap()
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 60))
        app.terminate(); app.launchArguments = ["--demo","--test-onboarding"]; app.launch()
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["guide-close"].exists)
        app.buttons["workspace-guide"].tap(); XCTAssertTrue(app.buttons["guide-close"].exists)
        app.buttons["guide-close"].tap(); app.terminate()
        app.launchEnvironment["PHOTONS_GUIDE_TEST_BUILD"] = token + "-B"; app.launch()
        XCTAssertTrue(app.staticTexts["guide-step-title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["guide-step-title"].label,"Welcome to Photons")
        app.buttons["guide-close"].tap()
    }
    @MainActor
    func testPanoramaGuideHighlightsModulesWithoutChangingAlignment() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.press(forDuration: 0.7)
        app.buttons["photo-Sample-02.tiff"].tap(); app.buttons["panorama-tool"].tap()
        app.buttons["choose-panorama-shift"].tap()
        let help = app.buttons["panorama-guide"], export = app.buttons["panorama-export"]
        XCTAssertTrue(export.wait(for: \.isEnabled,toEqual: true,timeout: 60))
        let hdr = app.buttons["panorama-display-mode"].frame
        help.tap()
        var titles = Set<String>()
        for _ in 0..<20 {
            let title = app.staticTexts["guide-step-title"].label
            titles.insert(title)
            let highlight = app.otherElements["guide-highlight"]
            XCTAssertTrue(highlight.exists,title)
            if title == "HDR / SDR panorama preview" {
                XCTAssertEqual(highlight.frame.minX,hdr.minX,accuracy: 4)
                XCTAssertEqual(highlight.frame.minY,hdr.minY,accuracy: 4)
            }
            if title == "Drag relative positions" {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Panorama draggable position tutorial"; shot.lifetime = .keepAlways; add(shot)
            }
            if title == "Render and export" {
                XCTAssertLessThan(highlight.frame.maxY,app.buttons["guide-close"].frame.minY)
            }
            if !app.buttons["guide-next"].isEnabled { break }
            app.buttons["guide-next"].tap()
        }
        XCTAssertTrue(titles.isSuperset(of: ["Panorama preview","Histogram","HDR / SDR panorama preview","Panorama controls","Camera and orientation","Drag relative positions","Select a frame and enter X / Y","Automatic or manually guided positions","Alignment options stay visible","Re-align to apply changes","Lens profile and LCC","Exposure and highlight brightness","Render and export"]))
        app.buttons["guide-close"].tap(); XCTAssertTrue(export.isEnabled)
        app.buttons["close-panorama"].tap(); XCTAssertTrue(app.scrollViews["photo-grid"].exists)
    }

    @MainActor
    func testChinesePerspectiveGuideInPortrait() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "zh-Hans"; app.launch()
        XCUIDevice.shared.orientation = .portrait
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.press(forDuration: 0.7)
        app.buttons["photo-Sample-02.tiff"].tap(); app.buttons["panorama-tool"].tap()
        app.buttons["choose-panorama-perspective"].tap()
        XCTAssertTrue(app.buttons["panorama-guide"].wait(for: \.isEnabled,toEqual: true,timeout: 60))
        app.buttons["panorama-guide"].tap()
        var titles = Set<String>()
        for _ in 0..<16 {
            titles.insert(app.staticTexts["guide-step-title"].label)
            XCTAssertTrue(app.otherElements["guide-highlight"].exists)
            if !app.buttons["guide-next"].isEnabled { break }
            app.buttons["guide-next"].tap()
        }
        XCTAssertTrue(titles.contains("透视接片布局")); XCTAssertTrue(titles.contains("透视模式中的 LCC"))
        XCTAssertFalse(titles.contains("自动或手动约束解算"))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Chinese portrait panorama export guide"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(app.buttons["guide-close"].label,"关闭")
        app.buttons["guide-close"].tap(); app.buttons["close-panorama"].tap()
    }
    @MainActor
    func testWorkspaceGuidesCoverToolbarAndSinglePhotoGestures() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60))
        let help = app.buttons["workspace-guide"]
        XCTAssertLessThan(help.frame.midX,app.buttons["import-photos"].frame.midX)
        help.tap()
        XCTAssertTrue(app.staticTexts["guide-step-title"].waitForExistence(timeout: 5))
        var titles = Set<String>()
        for _ in 0..<20 {
            titles.insert(app.staticTexts["guide-step-title"].label)
            XCTAssertTrue(app.otherElements["guide-highlight"].exists)
            if !app.buttons["guide-next"].isEnabled { break }
            app.buttons["guide-next"].tap()
        }
        XCTAssertTrue(titles.isSuperset(of: ["Browse and select photos","Library and folders","Grid view","Single-photo view","Replay this guide","Import photos","HDR / SDR preview","Start a panorama","Photo tools","Adjustments and history","Export and share","Settings and cache"]))
        let close = app.buttons["guide-close"]
        XCTAssertGreaterThan(close.frame.midX,app.frame.midX)
        XCTAssertGreaterThan(close.frame.midY,app.frame.midY)
        close.tap(); XCTAssertEqual(first.value as? String,"Not selected")
        first.doubleTap()
        XCTAssertTrue(app.otherElements["photo-canvas-container"].waitForExistence(timeout: 10))
        help.tap(); XCTAssertEqual(app.staticTexts["guide-step-title"].label,"View one photo")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@","swipe left or right")).firstMatch.exists)
        app.buttons["guide-next"].tap(); XCTAssertEqual(app.staticTexts["guide-step-title"].label,"Choose a zoom level")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Single photo zoom guide"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["guide-next"].tap(); XCTAssertEqual(app.staticTexts["guide-step-title"].label,"Move through the folder")
        close.tap(); XCTAssertTrue(app.otherElements["photo-canvas-container"].exists)
    }
    @MainActor
    func testGridSelectionKeepsCardFramesAndHonorsCollapsedInspector() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let cards = (1...3).map { app.buttons[String(format: "photo-Sample-%02d.tiff",$0)] }
        XCTAssertTrue(cards[0].waitForExistence(timeout: 60))
        let inspector = app.otherElements["workspace-inspector"], grid = app.scrollViews["photo-grid"]
        XCTAssertTrue(inspector.exists,"Wide grids reserve the inspector before any selection")
        let dockedFrames = cards.map(\.frame), dockedGridWidth = grid.frame.width
        func assertFrames(_ expected: [CGRect]) {
            for (card,frame) in zip(cards,expected) {
                XCTAssertEqual(card.frame.minX,frame.minX,accuracy: 0.5)
                XCTAssertEqual(card.frame.minY,frame.minY,accuracy: 0.5)
                XCTAssertEqual(card.frame.width,frame.width,accuracy: 0.5)
                XCTAssertEqual(card.frame.height,frame.height,accuracy: 0.5)
            }
        }
        cards[0].tap(); XCTAssertEqual(cards[0].value as? String,"Selected"); assertFrames(dockedFrames)
        cards[2].tap(); XCTAssertEqual(cards[2].value as? String,"Selected"); assertFrames(dockedFrames)
        let selected = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        selected.name = "Fixed grid with selected photo inspector"; selected.lifetime = .keepAlways; add(selected)
        cards[2].tap(); XCTAssertEqual(cards[2].value as? String,"Not selected"); assertFrames(dockedFrames)
        XCTAssertTrue(inspector.exists,"Deselecting empties the inspector without collapsing the grid")
        app.buttons["toggle-inspector"].tap()
        XCTAssertFalse(inspector.exists)
        XCTAssertGreaterThan(grid.frame.width,dockedGridWidth + 250)
        let expandedFrames = cards.map(\.frame)
        for (expanded,docked) in zip(expandedFrames,dockedFrames) {
            XCTAssertEqual(expanded.width,docked.width,accuracy: 0.5)
            XCTAssertEqual(expanded.height,docked.height,accuracy: 0.5)
        }
        cards[0].tap(); XCTAssertEqual(cards[0].value as? String,"Selected"); assertFrames(expandedFrames)
        XCTAssertFalse(inspector.exists,"Selection must respect the user's collapsed panel")
        app.buttons["toggle-inspector"].tap(); XCTAssertTrue(inspector.exists); assertFrames(dockedFrames)
        XCTAssertTrue(app.otherElements["RGB histogram"].exists)
        // Pinching remains an intentional size change, unlike selecting a photo.
        let oldWidth = cards[0].frame.width
        grid.pinch(withScale: oldWidth < 230 ? 1.5 : 0.65,velocity: oldWidth < 230 ? 1 : -1)
        XCTAssertGreaterThan(abs(cards[0].frame.width-oldWidth),oldWidth * 0.1)
    }
    @MainActor
    func testCompactGridFirstTapKeepsGridAndDoubleTapOpens() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .portrait
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60))
        guard app.frame.width < 950 else { throw XCTSkip("Run on an iPad with a compact portrait width") }
        first.tap(); XCTAssertEqual(first.value as? String,"Selected")
        XCTAssertFalse(app.otherElements["RGB histogram"].exists)
        // These are deliberately separate single taps. With immediate feedback two
        // successive automation tap() calls can fall inside UIKit's double-tap window.
        Thread.sleep(forTimeInterval: 0.7)
        first.tap(); XCTAssertEqual(first.value as? String,"Not selected")
        first.doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["photo-canvas"].waitForExistence(timeout: 10))
        app.buttons["grid-view"].tap()
        app.buttons["toggle-inspector"].tap()
        XCTAssertTrue(app.otherElements["RGB histogram"].waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(first.value as? String,"Not selected")
    }
    @MainActor
    func testGridDragDoesNotSelectPhoto() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60))
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.65))
        start.press(forDuration: 0.05,thenDragTo: start.withOffset(CGVector(dx: 0,dy: -100)))
        XCTAssertEqual(first.value as? String,"Not selected")
        XCTAssertFalse(app.buttons["finish-selection"].exists)
        XCTAssertTrue(app.scrollViews["photo-grid"].exists)
        first.tap(); XCTAssertEqual(first.value as? String,"Selected")
    }
    @MainActor
    func testOptionalLargeRAWZoomAt100PercentDoesNotCrash() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo","--boston"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["toggle-sidebar"].waitForExistence(timeout: 15))
        app.buttons["toggle-sidebar"].tap()
        guard app.buttons["load-boston"].exists else { throw XCTSkip("Optional locally bundled 100 MP RAW fixture") }
        app.buttons["toggle-sidebar"].tap()
        let photo = app.buttons["photo-B0000628.3FR"]
        XCTAssertTrue(photo.waitForExistence(timeout: 120)); photo.doubleTap()
        let canvas = app.otherElements["photo-canvas-container"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        let viewport = canvas.descendants(matching: .any)["photo-canvas"].firstMatch
        let state = canvas.staticTexts["zoom-state"], notice = canvas.staticTexts["detail-status"]
        canvas.buttons["zoom-options"].tap(); app.buttons["100%"].tap()
        viewport.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "100%",timeout: 10))
        XCTAssertTrue(notice.wait(for: \.label,toEqual: "Detail preview limited to 50% resolution",timeout: 60))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "100 percent RAW zoom with bounded detail"; shot.lifetime = .keepAlways; add(shot)
        viewport.swipeLeft()
        canvas.buttons["zoom-options"].tap(); app.buttons["200%"].tap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "200%",timeout: 10))
        XCTAssertTrue(notice.wait(for: \.label,toEqual: "Detail preview limited to 50% resolution",timeout: 60))
        app.buttons["display-mode"].tap()
        XCTAssertTrue(notice.wait(for: \.label,toEqual: "Detail preview limited to 50% resolution",timeout: 60))
        XCTAssertEqual(app.state,.runningForeground)
        canvas.buttons["zoom-fit"].tap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "Fit",timeout: 10))
        XCTAssertTrue(notice.waitForNonExistence(timeout: 10))
        canvas.buttons["zoom-options"].tap(); app.buttons["100%"].tap()
        viewport.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "100%",timeout: 10))
        XCTAssertTrue(notice.wait(for: \.label,toEqual: "Detail preview limited to 50% resolution",timeout: 60))
        XCTAssertEqual(app.state,.runningForeground)
    }
    @MainActor
    func testMultiSelectionTapsToggleWithoutOpeningPhotos() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"], second = app.buttons["photo-Sample-02.tiff"], third = app.buttons["photo-Sample-03.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.press(forDuration: 0.7)
        XCTAssertEqual(first.value as? String,"Selected")
        second.tap(); XCTAssertEqual(second.value as? String,"Selected")
        third.tap(); XCTAssertEqual(third.value as? String,"Selected")
        second.tap(); XCTAssertEqual(second.value as? String,"Not selected")
        third.tap(); XCTAssertEqual(third.value as? String,"Not selected")
        // Two quick taps are independent checkbox actions in selection mode.
        second.doubleTap(); XCTAssertEqual(second.value as? String,"Not selected")
        XCTAssertTrue(app.scrollViews["photo-grid"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["photo-canvas"].exists)
        app.buttons["finish-selection"].tap()
        second.doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["photo-canvas"].waitForExistence(timeout: 10))
    }
    @MainActor
    func testPanoramaZoomShowsPreviewNoticeAndFitClearsIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.press(forDuration: 0.7)
        app.buttons["photo-Sample-02.tiff"].tap(); app.buttons["panorama-tool"].tap()
        app.buttons["choose-panorama-shift"].tap()
        let preview = app.descendants(matching: .any)["panorama-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 60))
        let canvas = app.otherElements["panorama-preview-container"]
        canvas.buttons["zoom-options"].tap(); app.buttons["200%"].tap()
        preview.doubleTap()
        let notice = canvas.staticTexts["detail-status"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label,"Previewing low-res stitch")
        XCTAssertFalse(app.staticTexts["Rendering detail…"].exists)
        canvas.buttons["zoom-fit"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        app.buttons["close-panorama"].tap()
    }
    @MainActor
    func testPanoramaHistogramStaysInsidePreviewAndFolds() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--demo","--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"]="en";app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first=app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout:60));first.press(forDuration:0.7)
        app.buttons["photo-Sample-02.tiff"].tap();app.buttons["panorama-tool"].tap()
        app.buttons["choose-panorama-shift"].tap()
        let toggle=app.buttons["panorama-histogram-toggle"],plot=app.otherElements["panorama-histogram"].descendants(matching:.any)["histogram-plot"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout:60));XCTAssertTrue(plot.exists)
        let controls=app.scrollViews["panorama-controls"]
        XCTAssertLessThanOrEqual(plot.frame.maxX,controls.frame.minX)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Histogram inside preview";shot.lifetime = .keepAlways;add(shot)
        toggle.tap();XCTAssertTrue(plot.waitForNonExistence(timeout:5));XCTAssertTrue(toggle.exists)
        toggle.tap();XCTAssertTrue(plot.waitForExistence(timeout:5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertLessThanOrEqual(plot.frame.maxX,controls.frame.minX)
        app.buttons["close-panorama"].tap()
    }
    @MainActor
    func testLanguageChangesImmediatelyAndSystemDefaultLocalizesQuickStart() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo","--reset-demo","-AppleLanguages","(en)"]
        app.launch(); XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 60))
        app.buttons["settings-button"].tap(); app.buttons["interface-language"].tap(); app.buttons["English"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Language changes apply immediately."].waitForExistence(timeout: 5))
        app.buttons["close-settings"].tap(); app.buttons["photo-Sample-01.tiff"].tap()
        XCTAssertTrue(app.sliders["adjust-light.exposure"].waitForExistence(timeout: 30))
        app.buttons["settings-button"].tap(); app.buttons["interface-language"].tap(); app.buttons["简体中文"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["语言更改立即生效。"].waitForExistence(timeout: 5))
        app.buttons["close-settings"].tap()
        XCTAssertTrue(app.sliders["adjust-light.exposure"].exists,"Changing language must retain the inspector tab")
        XCTAssertTrue(app.staticTexts["曝光"].exists,"Cached adjustment titles must change too")
        app.buttons["workspace-guide"].tap(); XCTAssertEqual(app.staticTexts["guide-step-title"].label,"浏览与多选照片")
        app.buttons["guide-close"].tap(); app.buttons["settings-button"].tap()
        app.buttons["interface-language"].tap(); app.buttons["English"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Language changes apply immediately."].waitForExistence(timeout: 5))
        app.buttons["interface-language"].tap(); app.buttons["System default"].firstMatch.tap()
        app.buttons["close-settings"].tap(); app.terminate()
        app.launchArguments = ["--demo","--test-onboarding","-AppleLanguages","(zh-Hans)"]
        app.launchEnvironment["PHOTONS_GUIDE_TEST_BUILD"] = "system-language-" + UUID().uuidString
        app.launch()
        XCTAssertTrue(app.staticTexts["guide-step-title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["guide-step-title"].label,"欢迎使用 Photons")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Device language Chinese quick start"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["guide-close"].tap()
        app.buttons["settings-button"].tap(); app.buttons["interface-language"].tap(); app.buttons["English"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Language changes apply immediately."].waitForExistence(timeout: 5))
    }
    @MainActor
    func testChineseInterfaceCoversBrowsingSettingsAndLensDetails() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "zh-Hans"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.tap()
        XCTAssertTrue(app.otherElements["RGB 直方图"].waitForExistence(timeout: 15))
        let histogram = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); histogram.name = "Chinese grid and inspector"; histogram.lifetime = .keepAlways; add(histogram)
        first.doubleTap(); app.buttons["zoom-options"].tap()
        XCTAssertTrue(app.buttons["自定义…"].waitForExistence(timeout: 5)); app.buttons["自定义…"].tap()
        XCTAssertTrue(app.navigationBars["自定义倍率"].waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.tap()
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.buttons["interface-language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["语言更改立即生效。"].exists)
        let settings = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); settings.name = "Chinese settings"; settings.lifetime = .keepAlways; add(settings)
        app.buttons["镜头配置"].firstMatch.tap()
        app.buttons["lens-profile-43A1CC00-1115-4000-8000-000000000001"].tap()
        XCTAssertTrue(app.staticTexts["标定机身"].waitForExistence(timeout: 10))
        let lens = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); lens.name = "Chinese lens profile"; lens.lifetime = .keepAlways; add(lens)
    }
    @MainActor
    func testLensProfileOpensMetadataCoverageAndCaptureDetails() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 60))
        app.buttons["settings-button"].tap(); app.buttons["Lens profiles"].firstMatch.tap()
        let profile = app.buttons["lens-profile-43A1CC00-1115-4000-8000-000000000001"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10)); profile.tap()
        XCTAssertTrue(app.staticTexts["Calibration body"].waitForExistence(timeout: 10))
        let capture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profile-capture-")).firstMatch
        for _ in 0..<6 where !capture.isHittable { app.swipeUp() }
        XCTAssertTrue(capture.exists); capture.tap()
        XCTAssertTrue(app.staticTexts["Sensor size"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Lens profile capture details"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor
    func testSettingsMeasuresAndClearsPreviewCache() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 60))
        app.buttons["settings-button"].tap()
        let clear = app.buttons["clear-preview-cache"]
        for _ in 0..<3 where !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 10)); clear.tap()
        app.buttons["confirm-clear-cache"].firstMatch.tap()
        let count = app.descendants(matching: .any)["cache-file-count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"),object: count)],timeout: 10),.completed)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Preview cache settings"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["close-settings"].tap()
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 5))
    }
    @MainActor
    func testHistogramShowsClippingAndTouchReadout() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.tap()
        let plot = app.descendants(matching: .any)["histogram-plot"].firstMatch
        XCTAssertTrue(plot.waitForExistence(timeout: 15)); plot.tap()
        XCTAssertTrue(app.descendants(matching: .any)["histogram-readout"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["histogram-clipping"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "iPad histogram details"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor
    func testFoldersFilterMoveAndPersist() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60))
        app.buttons["toggle-sidebar"].tap(); app.buttons["new-library-folder"].tap()
        let name = app.textFields["library-folder-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Travel")
        app.buttons["save-library-folder"].tap(); XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        first.press(forDuration: 0.7)
        app.buttons["move-to-folder"].tap(); app.buttons["Move to Travel"].tap()
        app.buttons["Travel"].firstMatch.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photo-Sample-02.tiff"].exists)
        app.buttons["Unfiled"].firstMatch.tap()
        XCTAssertTrue(app.buttons["photo-Sample-02.tiff"].waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
    }
    @MainActor
    func testDoubleTapOpensPhotoAndSwipesNavigate() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.doubleTap()
        let name = app.staticTexts["current-photo-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); XCTAssertEqual(name.label,"Sample-01.tiff")
        let canvas = app.descendants(matching: .any)["photo-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10)); canvas.swipeLeft()
        XCTAssertTrue(name.wait(for: \.label,toEqual: "Sample-02.tiff",timeout: 10))
        canvas.swipeRight()
        XCTAssertTrue(name.wait(for: \.label,toEqual: "Sample-01.tiff",timeout: 10))
        canvas.swipeRight()
        XCTAssertEqual(name.label,"Sample-01.tiff")
        XCTAssertFalse(app.buttons["previous-photo"].isEnabled)
    }
    @MainActor
    func testDoubleTapTogglesFitAndSelectedMagnification() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.doubleTap()
        let state = app.staticTexts["zoom-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let canvas = app.descendants(matching: .any)["photo-canvas"].firstMatch
        app.buttons["zoom-options"].tap(); app.buttons["200%"].tap()
        XCTAssertEqual(state.label,"Fit")
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "200%",timeout: 10))
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "Fit",timeout: 10))
        app.buttons["zoom-options"].tap(); app.buttons["50%"].tap()
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "50%",timeout: 10))
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "Fit",timeout: 10))
        app.buttons["zoom-options"].tap(); app.buttons["Custom…"].tap()
        let input = app.textFields["zoom-custom-input"]
        input.tap(); input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,count: 3) + "150")
        XCTAssertEqual(input.value as? String,"150")
        app.buttons["zoom-custom-apply"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "150%",timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Custom 150 percent magnification"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["zoom-fit"].tap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "Fit",timeout: 10))
    }
    @MainActor
    func testGridInspectorToggleDeselectsPhoto() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60))
        func selection(_ value: String) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@",value),object: first)
            XCTAssertEqual(XCTWaiter.wait(for: [changed],timeout: 5),.completed)
        }
        first.tap()
        selection("Selected")
        XCTAssertTrue(app.otherElements["RGB histogram"].waitForExistence(timeout: 20))
        first.tap()
        selection("Not selected")
        XCTAssertFalse(app.otherElements["RGB histogram"].exists)
        first.tap()
        selection("Selected")
        app.buttons["toggle-inspector"].tap()
        selection("Not selected")
    }
    @MainActor
    func testGridInspectorSelectionAndPanoramaWorkflow() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
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
        // A repeated single tap clears selection and its histogram.
        XCTAssertTrue(app.otherElements["RGB histogram"].waitForNonExistence(timeout: 5))
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["finish-selection"].waitForExistence(timeout: 5))
        app.buttons["photo-Sample-02.tiff"].tap()
        XCTAssertTrue(app.buttons["panorama-tool"].waitForExistence(timeout: 5))
        app.buttons["panorama-tool"].tap()
        XCTAssertTrue(app.buttons["choose-panorama-shift"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["panorama-preview"].exists)
        app.buttons["choose-panorama-shift"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["panorama-preview"].waitForExistence(timeout: 90), app.debugDescription)
        let displayMode = app.buttons["panorama-display-mode"], originalMode = app.buttons["panorama-display-mode"].label
        displayMode.tap()
        XCTAssertNotEqual(displayMode.label,originalMode)
        displayMode.tap()
        XCTAssertEqual(displayMode.label,originalMode)
        let exposure = app.sliders["Exposure (EV)"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5),app.debugDescription)
        exposure.adjust(toNormalizedSliderPosition: 0.625)
        let resetBrightness = app.buttons["reset-panorama-brightness"]
        XCTAssertTrue(resetBrightness.isEnabled)
        let highlights = app.sliders["HDR highlight brightness (stops)"]
        highlights.adjust(toNormalizedSliderPosition: 0.25)
        let ready = NSPredicate(format: "enabled == true")
        XCTAssertTrue(app.buttons["panorama-export"].wait(for: \.isEnabled,toEqual: true,timeout: 15))
        let tone = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); tone.name = "Panorama exposure and HDR brightness"; tone.lifetime = .keepAlways; add(tone)
        resetBrightness.tap()
        XCTAssertFalse(resetBrightness.isEnabled)
        expectation(for: ready,evaluatedWith: app.buttons["panorama-export"])
        waitForExpectations(timeout: 15)
        for angle in [90,180,270,0] {
            let orientation = app.buttons["panorama.body.orientation.\(angle)"]
            XCTAssertTrue(orientation.exists)
            orientation.tap()
            XCTAssertEqual(orientation.value as? String,"Selected")
        }
        let angles = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); angles.name = "Body orientation diagrams"; angles.lifetime = .keepAlways; add(angles)
        let frame = app.descendants(matching: .any)["shift-frame-0"]
        XCTAssertTrue(frame.exists, app.debugDescription)
        let value = frame.value as? String
        let originalCenter = CGPoint(x: frame.frame.midX,y: frame.frame.midY)
        let start = frame.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 10, dy: -8)))
        XCTAssertNotEqual(frame.value as? String, value)
        XCTAssertEqual(frame.frame.midX-originalCenter.x,10,accuracy: 2)
        XCTAssertEqual(frame.frame.midY-originalCenter.y,-8,accuracy: 2)
        XCTAssertFalse(app.buttons["panorama-export"].isEnabled)
        let revert = app.buttons["revert-panorama-layout"]
        XCTAssertTrue(revert.isEnabled); revert.tap()
        XCTAssertEqual(frame.value as? String,value)
        XCTAssertEqual(frame.frame.midX,originalCenter.x,accuracy: 1)
        XCTAssertEqual(frame.frame.midY,originalCenter.y,accuracy: 1)
        XCTAssertFalse(revert.isEnabled)
        XCTAssertTrue(app.buttons["panorama-export"].isEnabled,"Revert restores the existing aligned preview immediately")
        // Grabbing away from the center must move the same geometric center by the finger delta.
        let corner = frame.coordinate(withNormalizedOffset: CGVector(dx: 0.2,dy: 0.25))
        corner.press(forDuration: 0.1,thenDragTo: corner.withOffset(CGVector(dx: 12,dy: 6)))
        XCTAssertEqual(frame.frame.midX-originalCenter.x,12,accuracy: 2)
        XCTAssertEqual(frame.frame.midY-originalCenter.y,6,accuracy: 2)
        revert.tap()
        XCTAssertEqual(frame.value as? String,value)
        let controls = app.scrollViews["panorama-controls"]
        func scrollControls() {
            // The diagram intentionally consumes drags over frames; scroll through the gutter.
            let start = controls.coordinate(withNormalizedOffset: CGVector(dx: 0.98,dy: 0.85))
            start.press(forDuration: 0.05,thenDragTo: controls.coordinate(withNormalizedOffset: CGVector(dx: 0.98,dy: 0.2)))
        }
        scrollControls()
        let deghost = app.switches["panorama-deghost"]
        if !deghost.isHittable { scrollControls() }
        XCTAssertEqual(deghost.value as? String, "1")
        let exportButton = app.buttons["panorama-export"]
        for expected in ["0", "1"] {
            deghost.tap()
            XCTAssertEqual(deghost.value as? String, expected)
            XCTAssertTrue(exportButton.wait(for: \.isEnabled, toEqual: true, timeout: 30))
        }
        let exposureMatch = app.switches["Match exposure"]
        if !exposureMatch.isHittable { scrollControls() }
        XCTAssertEqual(exposureMatch.value as? String, "1")
        exposureMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(exposureMatch.value as? String, "0", app.debugDescription)
        XCTAssertTrue(exportButton.wait(for: \.isEnabled, toEqual: false, timeout: 5))
        let update = app.buttons["align-panorama"]
        XCTAssertEqual(update.label, "Update seams")
        update.tap()
        XCTAssertTrue(exportButton.wait(for: \.isEnabled, toEqual: true, timeout: 30))
        XCTAssertEqual(update.label, "Update alignment")
        let crop = app.switches["panorama-crop-lcc"]
        if !crop.isHittable { scrollControls() }
        XCTAssertTrue(crop.exists)
        crop.tap()
        XCTAssertEqual(crop.value as? String,"1")
        XCTAssertFalse(app.buttons["panorama-export"].isEnabled, "A requested LCC crop must be applied before exporting")
        crop.tap()
        XCTAssertEqual(crop.value as? String,"0")
        XCTAssertTrue(app.buttons["panorama-export"].isEnabled)
        let workspace = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); workspace.name = "Large panorama workspace"; workspace.lifetime = .keepAlways; add(workspace)
        app.buttons["panorama-export"].tap()
        app.buttons["export-size"].tap()
        app.buttons["Full resolution"].tap()
        app.buttons["confirm-export"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Saved ")).firstMatch.waitForExistence(timeout: 90), app.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "iPad panorama workspace"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["General"].waitForExistence(timeout: 5))
        app.buttons["Photo library"].firstMatch.tap()
        XCTAssertTrue(app.switches["Skip duplicate imports"].waitForExistence(timeout: 5))
        app.buttons["Lens profiles"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Import lens profile"].waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); settings.name = "Full-screen settings tabs"; settings.lifetime = .keepAlways; add(settings)
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
