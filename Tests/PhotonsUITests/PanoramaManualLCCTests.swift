import AppKit
import CoreImage
import PhotonsExport
import PhotonsJobs
@testable import PhotonsPanorama
@testable import PhotonsUI
import XCTest

@MainActor
final class PanoramaManualLCCTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var savedProfile: String?
    private let preference = "Photons.panorama.lensProfileID"

    override func setUpWithError() throws {
        savedProfile = UserDefaults.standard.string(forKey: preference)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(savedProfile, forKey: preference)
        try FileManager.default.removeItem(at: directory)
    }

    private func wait(for condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private func workspace() throws -> PanoramaWindowModel {
        _ = NSApplication.shared
        let engine = PanoramaEngine(), size = CGSize(width: 96, height: 64)
        let images = [0.16, 0.22].map { level in
            CIImage(color: CIColor(red: level, green: 0.16, blue: 0.18, alpha: 1, colorSpace: PanoramaEngine.linearSpace)!)
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        let sources = try images.enumerated().map { i, image in
            let url = directory.appendingPathComponent("frame-\(i).tif")
            try CIContext().writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: PanoramaEngine.linearSpace)
            return try PanoramaSource(url: url)
        }
        let grid = LCCMeasurementGrid(x: [-12, 12], y: [8, -8], channels: ["R", "G", "B"],
            values: LCCMeasurementGrid.pack([0.3,0.3,0.3, 0.09,0.13,0.15, 0.2,0.27,0.3, 0.05,0.09,0.12]),
            standardError: nil, space: "apple-linear-srgb-6500K-v1")
        let capture = LCCProfileCapture(id: UUID(), filename: "test.tif", orientation: .landscape,
            shiftX: 0, shiftY: 0, sensorWidth: 36, sensorHeight: 24, pixelWidth: 96, pixelHeight: 64,
            iso: 64, exposureSeconds: 1, capturedAt: nil, grid: grid, thumbnail: nil)
        let profile = LCCLensProfile(id: UUID(), name: "Test LCC", camera: sources[0].camera,
            aperture: 11, notes: "", createdAt: Date(), captures: [capture])
        let store = LCCProfileStore(directory: directory.appendingPathComponent("profiles"))
        try store.save(profile)
        let plan = PanoramaPlan(sources: sources, origins: [.zero, CGPoint(x: 28, y: 0)],
            size: CGSize(width: 124, height: 64), registrationScores: [1,1], whiteBalance: nil, gains: [1,1],
            ownership: [], maskWidth: 0, maskHeight: 0,
            optical: OpticalEstimate(center: nil, confidence: 0, explanation: "", occludedEdges: []),
            options: PanoramaOptions(), previewScale: 1, previewImages: images, preview: nil)
        let model = PanoramaWindowModel(urls: sources.map(\.url), profileStore: store)
        model.choosingMode = false
        model.sensorChoice = 4
        model.sensorWidth = 36
        model.sensorHeight = 24
        model.selectedLensProfileID = profile.id.uuidString
        model.lensProfiles = [LCCProfileSummary(profile)]
        model.plan = try engine.applyingTone(engine.update(plan, options: model.options), settings: model.tone)
        return model
    }

    func testManualAlignmentFromDisabledCanOverrideAndRestoreMeasuredReference() async throws {
        let model = try workspace()
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 750),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        model.window = parent
        defer { model.cancel(); parent.close() }
        let hint = PanoramaShiftHint(x: .millimeters(3), y: .millimeters(-1))
        model.setShiftHint(index: 0, hint: hint, asReference: true)
        let original = try XCTUnwrap(model.plan?.preview)
        let reference = try XCTUnwrap(model.positionReference)
        let measured = reference.profileOffset(in: try XCTUnwrap(model.plan), sensor: try XCTUnwrap(model.sensor))

        model.alignLCC()
        try await wait { !model.busy }
        let first = try XCTUnwrap(model.alignmentWindow)
        XCTAssertTrue(first.window?.sheetParent === parent)
        XCTAssertFalse(model.lccEnabled)
        XCTAssertEqual(CGPoint(x: first.model.x, y: first.model.y), measured)
        first.model.x = 6
        first.close()
        XCTAssertNil(model.alignmentWindow)
        XCTAssertFalse(model.lccEnabled)
        XCTAssertTrue(model.plan?.preview === original)

        model.alignLCC()
        try await wait { !model.busy }
        let editor = try XCTUnwrap(model.alignmentWindow?.model)
        let manual = CGPoint(x: 5, y: 2)
        editor.x = manual.x
        editor.y = manual.y
        try await wait { !editor.working }
        editor.apply()
        XCTAssertTrue(model.lccEnabled)
        XCTAssertTrue(model.hasManualLCCPosition)
        XCTAssertEqual(model.shiftHints[0], hint)
        XCTAssertEqual(model.positionReference, reference)
        let plan = try XCTUnwrap(model.plan)
        XCTAssertTrue(plan.preview === editor.preview.preview)
        XCTAssertEqual(model.overviewReference?.profileOffset(in: plan, sensor: try XCTUnwrap(model.sensor)), manual)
        XCTAssertEqual(model.exportManifest(for: plan).profileOffsetMM, manual)
        XCTAssertTrue(model.canStitch)

        model.cropToLCC = true
        model.changeLCC()
        try await wait { !model.busy }
        XCTAssertEqual(model.plan?.lccState?.offsetMM, manual)
        XCTAssertNotNil(model.plan?.lccState?.cropRect)
        model.setLCCEnabled(false)
        try await wait { !model.busy }
        XCTAssertNil(model.plan?.lccState)
        model.setLCCEnabled(true)
        try await wait { !model.busy }
        XCTAssertTrue(model.canStitch)
        XCTAssertEqual(model.plan?.lccState?.offsetMM, manual)

        model.usePositionReference()
        try await wait { !model.busy }
        XCTAssertFalse(model.hasManualLCCPosition)
        XCTAssertEqual(model.plan?.lccState?.offsetMM, measured)
        XCTAssertTrue(model.canStitch)
    }

    func testApplyTransfersVisibleManualPreviewAndExportsItsCropAndPixels() async throws {
        let model = try workspace()
        model.lccEnabled = true
        model.cropToLCC = true
        model.changeLCC()
        try await wait { !model.busy }
        XCTAssertNil(model.error)
        let before = try XCTUnwrap(model.plan?.preview)
        let initialCrop = try XCTUnwrap(model.plan?.lccState?.cropRect)
        model.alignLCC()
        try await wait { !model.busy }
        let editor = try XCTUnwrap(model.alignmentWindow?.model)
        defer { model.cancel() }
        editor.x = 7
        editor.y = -2
        XCTAssertFalse(editor.canApply)
        editor.apply()
        XCTAssertTrue(model.plan?.preview === before)
        try await wait { !editor.working }
        XCTAssertTrue(editor.canApply, editor.error ?? "")
        let visible = try XCTUnwrap(editor.preview.preview)
        let crop = try XCTUnwrap(editor.preview.lccState?.cropRect)
        XCTAssertNotEqual(initialCrop, crop)
        XCTAssertEqual(visible.width, Int(crop.width))
        XCTAssertEqual(visible.height, Int(crop.height))
        editor.apply()
        let plan = try XCTUnwrap(model.plan)
        XCTAssertTrue(plan.preview === visible)
        XCTAssertNil(model.alignmentWindow)
        XCTAssertEqual(model.lccOffset, CGPoint(x: 7, y: -2))
        XCTAssertTrue(model.canStitch)
        let manifest = model.exportManifest(for: plan)
        let job = try PanoramaJob(snapshot: PanoramaSnapshot(plan: plan), manifest: manifest,
            preset: ExportPreset(format: .tiff, bitDepth: 16, sdrToneMapping: .none),
            linearDNG: false, outputDirectory: directory, bookmarks: [])
        let url = try XCTUnwrap(job.run { _,_ in })
        let written = try XCTUnwrap(PanoramaManifest.read(from: url))
        XCTAssertEqual(written.profileOffsetMM, plan.lccState?.offsetMM)
        XCTAssertEqual(written.crop, manifest.crop)
        let exported = try XCTUnwrap(CIImage(contentsOf: url))
        XCTAssertEqual(exported.extent.size, crop.size)
        func sample(_ image: CIImage, _ x: Int) -> [Float] {
            var pixel = [Float](repeating: 0, count: 4)
            CIContext().render(image, toBitmap: &pixel, rowBytes: 16,
                               bounds: CGRect(x: x, y: visible.height/2, width: 1, height: 1),
                               format: .RGBAf, colorSpace: PanoramaEngine.linearSpace)
            return pixel
        }
        for x in [visible.width/4, visible.width/2, visible.width*3/4] {
            let a = sample(CIImage(cgImage: visible), x), b = sample(exported, x)
            for channel in 0..<3 { XCTAssertEqual(a[channel], b[channel], accuracy: 0.008) }
        }
    }
}
