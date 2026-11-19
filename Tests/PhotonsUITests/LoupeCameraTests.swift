import XCTest
import CoreGraphics
import PhotonsCore
import PhotonsUI

/// 202 P3 — the camera's target state, as arithmetic.
///
/// Every case here is a question `LoupeController` used to answer inline: what the next
/// `LoupeViewState` is for a fit, a named stop, a ⌘=/⌘− step, a drag, a scroll or a pinch. The
/// controller's side effects (`setViewState`, the animation, the crop clamp) are not in reach, so
/// the formulas are asserted directly.
final class LoupeCameraTests: XCTestCase {

    private func framing() -> LoupeFraming {
        LoupeFraming(viewport: ImageSize(width: 1000, height: 800),
                     sourceWidth: 4000, sourceHeight: 3000, crop: .full)
    }

    private func camera(state: LoupeViewState = .fit, backingScale: Double = 2,
                        cropLimit: Double? = nil) -> LoupeCamera {
        LoupeCamera(viewport: LoupeViewport(framing: framing(), state: state),
                    backingScale: backingScale, cropLimit: cropLimit)
    }

    private func actual(zoom: Double, x: Double = 2000, y: Double = 1500) -> LoupeViewState {
        LoupeViewState(mode: .actual, zoom: zoom, centerX: x, centerY: y)
    }

    // MARK: 1

    func testFitKeepsCentreButClearsMode() {
        let state = actual(zoom: 2, x: 1234, y: 567)
        let next = camera(state: state).fitted()
        XCTAssertEqual(next.mode, .fit)
        XCTAssertEqual(next.zoom, 2)
        XCTAssertEqual(next.centerX, 1234)
        XCTAssertEqual(next.centerY, 567)
    }

    // MARK: 2

    func testActualSizeFromFitLandsOnOneAndKeepsTheAnchor() {
        let f = framing()
        let anchor = CGPoint(x: 250, y: 200)
        let before = f.sourcePoint(of: .fit, viewX: 250, viewY: 200, backingScale: 2)
        let next = camera(state: .fit).actualSize(aroundView: anchor)
        let after = f.sourcePoint(of: next, viewX: 250, viewY: 200, backingScale: 2)
        XCTAssertEqual(next.mode, .actual)
        XCTAssertEqual(next.zoom, 1, accuracy: 1e-12)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-9)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-9)
    }

    // MARK: 3

    func testZoomToStopSnapsDownToTheRung() {
        let next = camera().zoomed(to: 0.9, aroundView: CGPoint(x: 500, y: 400))
        XCTAssertEqual(next.mode, .actual)
        XCTAssertEqual(next.zoom, 2.0 / 3.0, accuracy: 1e-12)
    }

    // MARK: 4

    func testStepInFromFitIsActualSize() {
        XCTAssertEqual(camera(state: .fit).stepped(inward: true), .actualSize)
    }

    // MARK: 5

    func testStepOutFromLowestRungIsFit() {
        XCTAssertEqual(camera(state: actual(zoom: 0.125)).stepped(inward: false), .fit)
    }

    // MARK: 6

    func testPanOnlyInActualAndMovesByWindowPointsOverBackingScale() {
        let fit = camera(state: .fit)
        XCTAssertEqual(fit.panned(byWindowPoints: CGSize(width: 10, height: 0)), .fit)

        let zoomed = camera(state: actual(zoom: 1))
        let next = zoomed.panned(byWindowPoints: CGSize(width: 10, height: 0))
        XCTAssertEqual(next.centerX, 1980, accuracy: 1e-9)
        XCTAssertEqual(next.centerY, 1500, accuracy: 1e-9)
    }

    // MARK: 7

    func testPinchTracksFractionalScaleAndReversesAtTheLimit() {
        let point = CGPoint(x: 200, y: 150)
        let initial = camera(state: actual(zoom: 1))
        let state = initial.pinched(by: 1.037, aroundView: point).state
        XCTAssertEqual(state.zoom, 1.037, accuracy: 1e-12)
        let limited = camera(state: state).pinched(by: 20, aroundView: point).state
        XCTAssertEqual(limited.zoom, 8)
        XCTAssertEqual(camera(state: limited).pinched(by: 0.98, aroundView: point).state.zoom, 7.84, accuracy: 1e-12)
        XCTAssertEqual(initial.pinched(by: .nan, aroundView: point).state, initial.state)
    }

    func testPinchStartsAtTheDisplayedScaleWhenLargeImageFitsBelowTenPercent() {
        let f = LoupeFraming(viewport: ImageSize(width: 600, height: 400),
                             sourceWidth: 21000, sourceHeight: 9000, crop: .full)
        let camera = LoupeCamera(viewport: LoupeViewport(framing: f, state: .fit),
                                 backingScale: 2, cropLimit: nil)
        XCTAssertLessThan(f.fitZoom, 0.1)
        let next = camera.pinched(by: 1.02, aroundView: CGPoint(x: 140, y: 100)).state
        XCTAssertEqual(next.zoom, f.fitZoom * 1.02, accuracy: 1e-10)
        XCTAssertEqual(f.zoom(of: next), next.zoom)
    }

    // MARK: 8

    func testCropLimitCapsActualSize() {
        let next = camera(cropLimit: 0.6).actualSize(aroundView: CGPoint(x: 500, y: 400))
        XCTAssertEqual(next.mode, .actual)
        XCTAssertEqual(next.zoom, 0.6, accuracy: 1e-12)
    }

    // MARK: 9

    func testLabelSaysFitPercent() {
        XCTAssertEqual(camera(state: .fit).label, "适应 23%")
    }

    // MARK: 10

    func testCurrentStopIsNilAtFit() {
        XCTAssertNil(camera(state: .fit).currentStop)
    }
}
