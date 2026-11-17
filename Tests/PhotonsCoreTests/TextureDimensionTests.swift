import XCTest
import Metal
@testable import PhotonsCore

final class TextureDimensionTests: XCTestCase {
    func testOversizedSourceThrowsBeforeMetalCanAbort() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let maximum = MetalTextureLimits.maximum2DDimension(for: device)
        // A narrow strip exercises the real source-upload entry with tiny RAM usage.
        let image = LinearImage(width: maximum + 1, height: 1,
            rgba: [Float16](repeating: 0, count: (maximum + 1) * 4),
            colorSpace: "extendedLinearSRGB", decoderVersion: "test")
        XCTAssertThrowsError(try RenderGraph(input: .init(image: image, identity: "too-wide"))) { error in
            XCTAssertEqual((error as? TextureDimensionError)?.width, maximum + 1)
        }
        // Also reject height, including a rotated source, before allocating an upright copy.
        let rotated = LinearImage(width: maximum + 1, height: 1, rgba: image.rgba,
            colorSpace: "extendedLinearSRGB", decoderVersion: "test", orientation: .right)
        XCTAssertThrowsError(try RenderGraph(input: .init(image: rotated, identity: "too-tall"))) { error in
            XCTAssertEqual((error as? TextureDimensionError)?.height, maximum + 1)
        }
    }
}
