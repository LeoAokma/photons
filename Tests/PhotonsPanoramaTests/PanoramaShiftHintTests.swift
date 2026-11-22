import XCTest
@testable import PhotonsPanorama

final class PanoramaShiftHintTests: XCTestCase {
    func testOrientedCalibratedMaximumIsDistinctFromAReading() {
        let hint = PanoramaShiftHint(x: .negativeMaximum, y: .unknown)
        let rotated = hint.resolved(body: .alpa12Max, orientation: .degrees90, calibration: .cfv100cMax2026)
        XCTAssertEqual(rotated.x, -24.81)
        XCTAssertNil(rotated.y)
        XCTAssertNil(rotated.point)
        XCTAssertEqual(hint.resolved(body: .alpa12Max, orientation: .degrees90, calibration: nil).x, -25)
        XCTAssertEqual(hint.resolved(body: .alpa12XY, orientation: .degrees0, calibration: .cfv100cMax2026).x, -25)
        let number = PanoramaShiftHint(x: .millimeters(-18), y: .positiveMaximum)
        XCTAssertEqual(number.resolved(body: .alpa12Max, orientation: .degrees0, calibration: .cfv100cMax2026).point,
                       CGPoint(x: -18, y: 24.81))
    }

    func testUnknownAndConflictingAxesDoNotNarrowLCCSearch() {
        let full = -20.0...20.0
        XCTAssertEqual(LCCPositionSolver.guidedRange(full, origins: [4, 5]), 3.5...5.5)
        XCTAssertEqual(LCCPositionSolver.guidedRange(full, origins: []), full)
        XCTAssertEqual(LCCPositionSolver.guidedRange(full, origins: [-15, 15]), full)
        XCTAssertEqual(LCCPositionSolver.guidedRange(full, origins: [30]), full)
        let delta = PanoramaShiftPosition(x: 3, y: 2).difference(from: .init(y: -1), pixelsPerMM: CGSize(width: 4, height: 5))
        XCTAssertNil(delta.x)
        XCTAssertEqual(delta.y, -15)
    }

    func testBoundedDescriptorIndexMatchesTheSameStripOnEitherAxis() throws {
        let width = 192, height = 160
        let pixels = (0..<(width * height)).map { i in Double((i &* 7_491 ^ (i / width) &* 13_331) & 255) / 255 }
        let raster = GrayRaster(width: width, height: height, values: pixels)
        let token = PanoramaCancellation()
        let all = try TranslationRegistration.correspondences(raster, raster, cancellation: token)
        XCTAssertGreaterThan(all.count, 30)
        XCTAssertTrue(try TranslationRegistration.correspondences(raster, raster, expected: .init(x: 0),
                                                                   radius: -1, cancellation: token).isEmpty)
        for expected in [PanoramaShiftPosition(x: 1.5), .init(y: -1.5), .init(x: 1.5, y: -1.5)] {
            let guided = try TranslationRegistration.correspondences(raster, raster, expected: expected,
                                                                    radius: 1.5, cancellation: token)
            XCTAssertFalse(guided.isEmpty)
            for pair in guided {
                if let x = expected.x { XCTAssertLessThanOrEqual(abs(pair.a.x - pair.b.x - x), 1.5) }
                if let y = expected.y { XCTAssertLessThanOrEqual(abs(pair.a.y - pair.b.y - y), 1.5) }
            }
            let selfMatches = guided.filter { $0.a == $0.b }.map(\.a)
            for pair in all where pair.a == pair.b { XCTAssertTrue(selfMatches.contains(pair.a)) }
        }
    }

    func testImageDeterminesBothAxesWithCorrectOrIncorrectReading() throws {
        let w = 192, h = 144
        var state: UInt64 = 71
        let data: [Double] = (0..<(w * 2 * h)).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Double(state >> 32) / Double(UInt32.max)
        }
        func tile(_ dx: Int, _ dy: Int) -> GrayRaster {
            GrayRaster(width: w, height: h - 16, values: (0..<(h-16)).flatMap { y in
                let start = (y + dy) * w * 2 + dx
                return data[start..<(start + w)]
            })
        }
        let left = tile(0, 0), right = tile(30, 8)
        for hint in [PanoramaShiftPosition(x: 33), .init(y: 5), .init(x: -60, y: -40)] {
            let match = try XCTUnwrap(TranslationRegistration.align(left, right, expected: hint, radius: 6, cancellation: .init()))
            XCTAssertEqual(match.offset.x, 30, accuracy: 0.2)
            XCTAssertEqual(match.offset.y, 8, accuracy: 0.2)
        }
    }
}
