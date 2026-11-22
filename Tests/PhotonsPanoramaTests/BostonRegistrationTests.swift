import XCTest
import CoreImage
import ImageIO
@testable import PhotonsPanorama

/// Optional real-camera regression fixtures; never require private photos in CI.
final class BostonRegistrationTests: XCTestCase {
    func testDeghostAfterLCCOnBoston591And592() throws {
        guard let folder = ProcessInfo.processInfo.environment["PHOTONS_BOSTON_DIR"] else {
            throw XCTSkip("Set PHOTONS_BOSTON_DIR for the 591–592 post-LCC regression")
        }
        let root = URL(fileURLWithPath: folder)
        let urls = ["B0000591.3FR", "B0000592.3FR"].map { root.appendingPathComponent($0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = LCCProfileStore(directory: directory)
        try profiles.installBundledProfile()
        let profile = try profiles.load(LCCLensProfile.builtInID)
        let fields = try LCCCorrectionEngine.fields(profile)
        let engine = PanoramaEngine()
        let prepared = try engine.prepareLCCImages(engine.analyze(urls: urls))
        let sensor = try XCTUnwrap(prepared.sources.first?.sensor)
        let position = try LCCPositionSolver.solve(plan: prepared, fields: fields, sensor: sensor, allowPairedFlats: false)
        let corrected = try engine.applyingLCC(prepared, profile: profile, fields: fields,
            offsetMM: position.offsetMM, sensor: sensor, crop: false, cameraBody: .alpa12Max)
        let lcc = try XCTUnwrap(corrected.lccState)
        var options = corrected.options
        options.avoidMotion = false
        XCTAssertEqual(corrected.previewStatus(for: options, mode: .shift, alignmentChanged: false), .needsSeamUpdate)
        let off = try engine.update(corrected, options: options)
        let on = try engine.update(off, options: corrected.options)
        for result in [off, on] {
            XCTAssertEqual(result.previewStatus(for: result.options, mode: .shift, alignmentChanged: false), .current)
            XCTAssertEqual(result.origins, corrected.origins)
            XCTAssertEqual(result.outputSize, corrected.outputSize)
            XCTAssertEqual(result.lccState?.profileID, profile.id)
            XCTAssertEqual(result.lccState?.offsetMM, lcc.offsetMM)
            XCTAssertEqual(result.lccState?.coveredFraction, lcc.coveredFraction)
            XCTAssertNotNil(result.preview)
        }
        XCTAssertFalse(PanoramaManifest(plan: off).options.avoidMotion)
        XCTAssertNotEqual(off.blendMasks, corrected.blendMasks)
        XCTAssertEqual(on.blendMasks, corrected.blendMasks)
        print("591–592 post-LCC", corrected.outputSize, "coverage", lcc.coveredFraction)
    }

    func testBoston604Through607WithHorizontalStopsOrImageEvidenceAlone() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_BOSTON_DIR"] else {
            throw XCTSkip("Set PHOTONS_BOSTON_DIR for Boston 604–607")
        }
        let root = URL(fileURLWithPath: path)
        // Independent feature matches in the oriented, 1536-pixel-wide camera previews.
        let measured: [(Int, Int, CGPoint)] = [
            (604, 605, CGPoint(x: -1268.32, y: -2.59)), (604, 607, CGPoint(x: -0.85, y: 976.68)),
            (605, 606, CGPoint(x: -2.07, y: 975.51)), (606, 607, CGPoint(x: 1269.35, y: 0.99))
        ]
        for (reversed, guided) in [(false, false), (false, true), (true, false)] {
            try autoreleasepool {
                let ids = reversed ? Array((604...607).reversed()) : Array(604...607)
                let urls = ids.map { root.appendingPathComponent(String(format: "B%07d.3FR", $0)) }
                var hints: [Int: PanoramaShiftPosition] = [:]
                if guided {
                    for (i, id) in ids.enumerated() { hints[i] = .init(x: [605, 606].contains(id) ? -18 : 18) }
                }
                let plan = try PanoramaEngine().analyze(urls: urls, shiftHints: hints)
                XCTAssertTrue(plan.isRegistered)
                XCTAssertNotNil(plan.preview)
                XCTAssertNil(plan.warps)
                let scale = 1536 / plan.sources[0].size.width
                let origins = Dictionary(uniqueKeysWithValues: zip(ids, plan.origins))
                for (a, b, expected) in measured {
                    let first = try XCTUnwrap(origins[a]), second = try XCTUnwrap(origins[b])
                    XCTAssertEqual((second.x-first.x)*scale, expected.x, accuracy: 2)
                    XCTAssertEqual((second.y-first.y)*scale, expected.y, accuracy: 2)
                }
                let restored = try PanoramaSnapshot(plan: plan).plan()
                XCTAssertEqual(restored.origins, plan.origins)
            }
        }
    }

    func testBostonStripsAndConfirmedGroups() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_BOSTON_DIR"] else {
            throw XCTSkip("Set PHOTONS_BOSTON_DIR to the external Boston RAW fixtures")
        }
        let root = URL(fileURLWithPath: path)
        let selected = ProcessInfo.processInfo.environment["PHOTONS_BOSTON_GROUP"]
        let groups = selected == "650" ? [650...658] : [628...633, 641...643, 644...646, 653...658, 659...662]
        for range in groups {
            if let selected, selected != String(range.lowerBound) { continue }
            try autoreleasepool {
                let urls = range.map { root.appendingPathComponent(String(format: "B%07d.3FR", $0)) }
                do {
                    let plan = try PanoramaEngine().analyze(urls: urls) { FileHandle.standardError.write(Data("BOSTON \(range.lowerBound) \($0)\n".utf8)) }
                    print("BOSTON RESULT", range.lowerBound, plan.origins, plan.registrationScores, plan.size)
                    XCTAssertEqual(plan.sources.count, range.count)
                    XCTAssertTrue(plan.registrationScores.allSatisfy { $0 > 0.7 })
                    let preview = try XCTUnwrap(plan.preview)
                    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("photons-boston-\(range.lowerBound).png")
                    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, preview, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(dest))
                } catch { XCTFail("Boston \(range): \(error)") }
            }
        }
    }
}
