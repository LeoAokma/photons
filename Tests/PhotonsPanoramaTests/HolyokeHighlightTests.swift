import XCTest
import CoreImage
@testable import PhotonsPanorama

final class HolyokeHighlightTests: XCTestCase {
    func testTreeEdgeHighlightsSurviveWorkerExport() throws {
        guard let folder = ProcessInfo.processInfo.environment["PHOTONS_HOLYOKE_DIR"] else {
            throw XCTSkip("Set PHOTONS_HOLYOKE_DIR to the Holyoke RAW fixture directory")
        }
        let root = URL(fileURLWithPath: folder)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LCCProfileStore(directory: directory)
        try store.installBundledProfile()
        let profile = try store.load(LCCLensProfile.builtInID)
        let fields = try LCCCorrectionEngine.fields(profile)

        // Measured tree lines in the 1400-pixel-wide registered panoramas.
        let cases = [(496...501, 615..<756, 590..<637, 0.04), (504...505, 480..<730, 354..<405, 0.02)]
        for (frames, columns, rows, tolerance) in cases {
            try autoreleasepool {
                let urls = frames.map { root.appendingPathComponent(String(format: "B%07d.3FR", $0)) }
                let engine = PanoramaEngine()
                let plan = try engine.analyze(urls: urls)
                let prepared = try engine.prepareLCCImages(plan)
                let sensor = try XCTUnwrap(plan.sources.first?.sensor)
                let position = try LCCPositionSolver.solve(plan: prepared, fields: fields, sensor: sensor, cameraBody: .alpa12Max)
                let corrected = try engine.applyingLCC(prepared, profile: profile, fields: fields, offsetMM: position.offsetMM,
                                                      sensor: sensor, crop: false, cameraBody: .alpa12Max)
                let scale = 1400 / plan.size.width
                func raster(_ image: CIImage) -> PanoramaRaster {
                    PanoramaRaster(image: image, context: engine.context, width: 1400, height: Int(image.extent.height))
                }
                func preview(_ plan: PanoramaPlan) -> PanoramaRaster {
                    raster(engine.composite(plan, images: plan.previewImages, imageScale: plan.previewScale, outputScale: scale))
                }
                let original = preview(plan), screen = preview(corrected)
                let bytes = try JSONEncoder().encode(PanoramaSnapshot(plan: corrected))
                let restored = try JSONDecoder().decode(PanoramaSnapshot.self, from: bytes).plan()
                let export = try raster(engine.renderComposite(restored, outputLongEdge: 1400))
                guard screen.height == original.height, export.height == original.height,
                      rows.upperBound < original.height, columns.upperBound < original.width else {
                    return XCTFail("Unexpected panorama extent for the measured tree line")
                }
                let a = screen.rgba, b = export.rgba
                var differences: [Double] = []
                for y in rows {
                    for x in columns {
                        let i = (y * original.width + x) * 4, green = original.rgba[i + 1]
                        // Select smooth bright sky using only the independent, uncorrected image.
                        guard original.rgba[i + 2] > original.rgba[i] * 1.1, green > 0.55,
                              abs(green - original.rgba[i + 5]) < 0.025,
                              abs(green - original.rgba[i + original.width * 4 + 1]) < 0.025 else { continue }
                        guard min(a[i + 1], a[i + 2], b[i + 1], b[i + 2]) > 0 else {
                            return XCTFail("Expected positive green and blue signals in bright sky")
                        }
                        differences.append(abs(log2(Double(a[i + 1] / a[i + 2]) / Double(b[i + 1] / b[i + 2]))))
                    }
                }
                XCTAssertGreaterThan(differences.count, 500)
                guard !differences.isEmpty else { return }
                let p95 = differences.sorted()[Int(0.95 * Double(differences.count))]
                print("Holyoke \(frames): \(differences.count) sky samples, preview/export G:B difference p95 \(p95) stops")
                XCTAssertLessThan(p95, tolerance)
            }
        }
    }
}
