import XCTest
import AppKit
import SwiftUI
@testable import PhotonsUI

@MainActor
final class AdjustmentSliderTests: XCTestCase {
    func testKeyboardAndAccessibilityKeepEditTransactionsAndStep() {
        let slider = AdjustmentNSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 16))
        slider.minValue = -4; slider.maxValue = 4; slider.doubleValue = 0; slider.valueStep = 0.05
        var edits: [Bool] = []
        slider.editingChanged = { edits.append($0) }
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: 124)!
        slider.keyDown(with: right)
        XCTAssertEqual(slider.doubleValue, 0.05, accuracy: 0.0001)
        XCTAssertEqual(edits, [true, false])
        XCTAssertTrue(slider.accessibilityPerformDecrement())
        XCTAssertEqual(slider.doubleValue, 0, accuracy: 0.0001)
        XCTAssertEqual(edits, [true, false, true, false])
        slider.isEnabled = false
        XCTAssertFalse(slider.accessibilityPerformIncrement())
        XCTAssertEqual(slider.doubleValue, 0)
    }

    func testDoubleClickOnTrackResetsWithoutCommittingTheFirstClick() {
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 250, height: 66),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let slider = AdjustmentNSSlider(frame: NSRect(x: 15, y: 20, width: 210, height: 20))
        slider.minValue = -4; slider.maxValue = 8; slider.doubleValue = 2
        var edits = [Bool](), resets = 0
        slider.editingChanged = { edits.append($0) }
        slider.onReset = { slider.doubleValue = 0; resets += 1 }
        window.contentView?.addSubview(slider)
        window.makeKeyAndOrderFront(nil)
        CropUITestSupport.pump(0.1)
        let point = slider.convert(NSPoint(x: 180, y: 10), to: nil)
        for count in 1...2 {
            let up = CropUITestSupport.mouse(.leftMouseUp, at: point, in: window, clickCount: count)
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(CropUITestSupport.mouse(.leftMouseDown, at: point, in: window, clickCount: count))
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                window.sendEvent(pending)
            }
            CropUITestSupport.pump(0.04)
        }
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(slider.doubleValue, 0)
        XCTAssertTrue(edits.isEmpty, "Undo should go directly back to the pre-double-click edit")
    }

    func testHandleIsWideRoundedRectangle() throws {
        let cell = AdjustmentSliderCell()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        cell.drawKnob(NSRect(x: 10, y: 10, width: 20, height: 20))
        NSGraphicsContext.restoreGraphicsState()
        // Symmetric rows and columns around (20,20): wider than tall, with solid shoulders.
        XCTAssertGreaterThan(rep.colorAt(x: 14, y: 17)?.alphaComponent ?? 0, 0.9)
        XCTAssertGreaterThan(rep.colorAt(x: 25, y: 22)?.alphaComponent ?? 0, 0.9)
        XCTAssertLessThan(rep.colorAt(x: 20, y: 13)?.alphaComponent ?? 1, 0.05)
        XCTAssertLessThan(rep.colorAt(x: 12, y: 20)?.alphaComponent ?? 1, 0.1, "Allow the half-point outline's antialiased fringe")
    }
}
