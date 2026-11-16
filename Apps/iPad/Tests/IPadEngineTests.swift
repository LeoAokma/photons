import XCTest
import CoreImage
import ImageIO
import PhotonsCore
import PhotonsCatalog
import PhotonsPanorama
@testable import PhotonsMobile
@testable import PhotonsExtensions

final class IPadEngineTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }
    private func engine() -> MobileEngine { MobileEngine(libraryURL: folder.appendingPathComponent("Test.photonslibrary")) }

    func testImportDuplicatesRenderAndPersistentHistory() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("samples"))
        let first = try await engine.importPhotos(urls, skipDuplicates: true, progress: { _,_ in })
        XCTAssertEqual(first.added, 3)
        let duplicate = try await engine.importPhotos(urls, skipDuplicates: true, progress: { _,_ in })
        XCTAssertEqual(duplicate.added, 0)
        let copies = try await engine.importPhotos([urls[0]], skipDuplicates: false, progress: { _,_ in })
        XCTAssertEqual(copies.added, 1)
        let photos = try await engine.photos()
        XCTAssertEqual(photos.count, 4)
        let photo = try XCTUnwrap(photos.first)
        var edit = EditModel.neutral
        let original = try await engine.frame(photo, edit: edit, hdr: false, edge: 256)
        XCTAssertGreaterThan(try XCTUnwrap(original.histogram).sampleCount, 0)
        edit.light.exposure = 1.0
        let changed = try await engine.frame(photo, edit: edit, hdr: false, edge: 256)
        XCTAssertNotEqual(original.histogram?.binsDigest(), changed.histogram?.binsDigest())
        var history = EditHistory(baseline: .neutral)
        history.commit(edit, label: "Exposure", coalesce: false)
        try await engine.save(edit, history: history, id: photo.id)
        let reopened = self.engine()
        let saved = try await reopened.edit(photo.id)
        XCTAssertEqual(saved.light.exposure, 1)
        var savedHistory = try await reopened.history(photo.id)
        XCTAssertEqual(savedHistory.undo()?.light.exposure, 0)
        let thumb = try await engine.thumbnail(photo, hdr: false)
        let cached = try await reopened.thumbnail(photo, hdr: false)
        XCTAssertEqual(thumb.histogram, cached.histogram)
        XCTAssertEqual(thumb.image.width, cached.image.width)
    }

    func testPanoramaAlignmentScaledLosslessExportAndMetadata() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("samples"))
        _ = try await engine.importPhotos(urls, skipDuplicates: true, progress: { _,_ in })
        let photos = try await engine.photos()
        var options = PanoramaOptions(); options.matchExposure = false; options.avoidMotion = false
        let plan = try await engine.analyze(photos, options: options, positions: [:], sensor: nil,
                                           cancellation: .init(), progress: { _,_ in })
        XCTAssertEqual(plan.sources.count, 3)
        XCTAssertEqual(plan.size.width, 1208, accuracy: 3)
        XCTAssertEqual(plan.size.height, 512, accuracy: 3)
        XCTAssertEqual(plan.origins[1].x - plan.origins[0].x, 220, accuracy: 2)
        let composite = try PanoramaEngine().renderComposite(plan, outputLongEdge: 604)
        XCTAssertEqual(composite.extent.width, 604, accuracy: 1)
        XCTAssertEqual(composite.extent.height, 256, accuracy: 1)
        var settings = MobileExportSettings(); settings.format = "dng"; settings.longEdge = 604
        let output = try await engine.export(photo: nil, edit: .neutral, plan: plan, manifest: nil, settings: settings,
                                             cancellation: .init(), progress: { _,_ in })
        XCTAssertTrue(output.lastPathComponent.hasPrefix("Sample-01_pano"))
        let manifest = try XCTUnwrap(PanoramaManifest.read(from: output))
        XCTAssertEqual(manifest.frames.count, 3)
        XCTAssertEqual(manifest.canvas.width, plan.size.width)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        // IFD0 is the embedded preview; CIRAWFilter resolves the full-resolution SubIFD.
        XCTAssertEqual(try PanoramaSource(url: output).size.width, 604, accuracy: 1)
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual((tiff?[kCGImagePropertyTIFFCompression as String] as? NSNumber)?.intValue, 7)
        let imported = try await engine.photos()
        XCTAssertEqual(imported.count, 4)
        let frame = try await engine.frame(plan, hdr: false)
        XCTAssertNotNil(frame.histogram)
        // A resized/cropped ordinary export of a reimported DNG must keep its original stitch geometry.
        let reimported = try XCTUnwrap(imported.first { $0.name == output.lastPathComponent })
        var cropEdit = EditModel.neutral; cropEdit.geometry.crop = .init(x: 0.25,y: 0.125,width: 0.5,height: 0.75)
        settings.format = "tiff"; settings.hdr = false; settings.longEdge = 160
        let copy = try await engine.export(photo: reimported,edit: cropEdit,plan: nil,manifest: nil,settings: settings,
                                          cancellation: .init(),progress: { _,_ in })
        let carried = try XCTUnwrap(PanoramaManifest.read(from: copy))
        XCTAssertEqual(carried.frames.count,3)
        let point = carried.canvasPoint(u: 0.25,v: 0.5)
        XCTAssertEqual(point.x,0.375,accuracy: 1e-8); XCTAssertEqual(point.y,0.5,accuracy: 1e-8)
    }

    func testTraditionalAndProfileLCCUseTheSharedPipeline() async throws {
        let flat = try makeFlat(name: "flat.dng", exposure: 1)
        let scene = try makeFlat(name: "scene.dng", exposure: 0.5)
        let source = try PanoramaSource(url: scene, sensorOverride: .init(width: 36,height: 24,source: "Generated fixture"))
        XCTAssertNotNil(source.sensor)
        let corrected = try LCCCorrectionEngine.traditional(scene: source, flatURL: flat)
        XCTAssertNotNil(corrected.preview)
        XCTAssertTrue(try XCTUnwrap(corrected.lccState).complete)
        var calibration = try LCCCreationFrame(url: flat); calibration.shiftConfirmed = true
        let sensor = try XCTUnwrap(source.sensor)
        let profile = try LCCProfileBuilder.create(name: "Generated calibration", aperture: nil, notes: "Test fixture", frames: [calibration],
            sensorLongEdge: max(sensor.width, sensor.height), sensorShortEdge: min(sensor.width, sensor.height))
        let roundTrip = try LCCProfileCodec.decode(LCCProfileCodec.encode(profile))
        let fromProfile = try LCCCorrectionEngine.single(scene: source, profile: roundTrip, position: .zero, refine: false)
        XCTAssertEqual(fromProfile.position, .zero)
        XCTAssertEqual(fromProfile.plan.preview?.width, corrected.preview?.width)
        let context = CIContext()
        let preview = CIImage(cgImage: try XCTUnwrap(fromProfile.plan.preview))
        var sample = [Float](repeating: 0, count: 9 * 4)
        context.render(preview.transformed(by: .init(scaleX: 3 / preview.extent.width, y: 3 / preview.extent.height)),
            toBitmap: &sample, rowBytes: 3 * 16, bounds: CGRect(x: 0,y: 0,width: 3,height: 3), format: .RGBAf,
            colorSpace: PanoramaEngine.linearSpace)
        XCTAssertLessThan(abs(sample[1] - sample[4 * 4 + 1]), 0.08, "LCC should flatten the generated falloff")
    }

    func testLCCCoverageCropUpdatesPreviewExportAndCanBeRemoved() async throws {
        let flat = try makeFlat(name: "crop-flat.dng", exposure: 1)
        let scene = try makeFlat(name: "crop-scene.dng", exposure: 0.5)
        let sensor = SensorSize(width: 36,height: 24,source: "Generated fixture")
        let source = try PanoramaSource(url: scene,sensorOverride: sensor)
        var calibration = try LCCCreationFrame(url: flat); calibration.shiftConfirmed = true
        let profile = try LCCProfileBuilder.create(name: "Coverage crop test", aperture: nil, notes: "Generated test fixture", frames: [calibration],
            sensorLongEdge: 36,sensorShortEdge: 24)
        let profileURL = try LCCProfileStore().save(profile)
        defer { try? FileManager.default.removeItem(at: profileURL) }
        let engine = engine(), base = try PanoramaEngine().singlePhoto(source)
        // Move the photo beyond the calibration's measured footprint to require a real crop.
        let cropped = try await engine.correctPanorama(base,profileID: profile.id,offset: CGPoint(x: 8,y: 0),
            body: .alpa12Max,orientation: .degrees0,cropToCoverage: true,cancellation: .init(),progress: { _,_ in })
        let state = try XCTUnwrap(cropped.lccState), rect = try XCTUnwrap(state.cropRect)
        XCTAssertFalse(state.complete)
        XCTAssertEqual(rect,state.suggestedCropRect)
        XCTAssertGreaterThan(rect.width,0); XCTAssertLessThan(rect.width,base.size.width)
        XCTAssertEqual(cropped.outputSize,rect.size)
        XCTAssertEqual(try XCTUnwrap(cropped.preview).width,Int(rect.width))
        let uncropped = try await engine.setLCCCrop(cropped,enabled: false,cancellation: .init())
        XCTAssertNil(uncropped.lccState?.cropRect)
        XCTAssertEqual(uncropped.outputSize,base.size)
        XCTAssertEqual(uncropped.lccState?.offsetMM,state.offsetMM)
        XCTAssertEqual(uncropped.lccState?.profileID,state.profileID)
        let restored = try await engine.setLCCCrop(uncropped,enabled: true,cancellation: .init())
        XCTAssertEqual(restored.lccState?.cropRect,rect)
        var settings = MobileExportSettings(); settings.format = "dng"; settings.longEdge = 2048
        let output = try await engine.export(photo: nil,edit: .neutral,plan: restored,manifest: nil,settings: settings,
            cancellation: .init(),progress: { _,_ in })
        XCTAssertEqual(try PanoramaSource(url: output).size,rect.size)
        let manifest = try XCTUnwrap(PanoramaManifest.read(from: output))
        XCTAssertTrue(manifest.correctionApplied)
        XCTAssertEqual(manifest.crop.minX,rect.minX/base.size.width,accuracy: 1e-8)
        XCTAssertEqual(manifest.crop.width,rect.width/base.size.width,accuracy: 1e-8)
    }

    func testOptionalRealRAWWorkflow() async throws {
        let inputs = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0].appendingPathComponent("ValidationInputs")
        let bundled = MobileSamples.boston
        let urls = (bundled.isEmpty ? ((try? FileManager.default.contentsOfDirectory(at: inputs,includingPropertiesForKeys: nil)) ?? []) : bundled)
            .filter { ["3fr","dng"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard urls.count >= 2 else { throw XCTSkip("No optional RAW fixtures supplied; use a local Boston sample build or Documents/ValidationInputs.") }
        let engine = engine()
        let photos = urls.enumerated().map { MobilePhoto(id: "real-\($0.offset)",name: $0.element.lastPathComponent,
            url: $0.element,rating: 0,width: 0,height: 0) }
        let preview = try await engine.frame(photos[0],edit: .neutral,hdr: true,edge: 1200)
        XCTAssertGreaterThan(preview.image.width,100)
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,cancellation: .init(),
                                           progress: { text,_ in print("RAW ALIGN",text) })
        XCTAssertEqual(plan.sources.count,photos.count)
        _ = try await engine.profiles()
        let corrected = try await engine.correctPanorama(plan,profileID: LCCLensProfile.builtInID,offset: nil,
            body: .alpa12Max,orientation: .degrees0,cancellation: .init(),progress: { text,_ in print("RAW LCC",text) })
        XCTAssertNotNil(corrected.lccState)
        var settings = MobileExportSettings();settings.format = "dng";settings.longEdge = 2048
        let output = try await engine.export(photo: nil,edit: .neutral,plan: corrected,manifest: nil,settings: settings,
                                            cancellation: .init(),progress: { text,_ in print("RAW EXPORT",text) })
        XCTAssertTrue(try XCTUnwrap(PanoramaManifest.read(from: output)).correctionApplied)
        print("REAL RAW SUCCESS",plan.size,output.lastPathComponent)
    }

    func testPerspectiveModeFitsWarpAndPreservesCaptureModel() async throws {
        let urls = try MobileSamples.create(in: folder.appendingPathComponent("perspective"))
        let input = try XCTUnwrap(CIImage(contentsOf: urls[1]))
        let warped = input.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: 0,y: 512), "inputTopRight": CIVector(x: 768,y: 498),
            "inputBottomLeft": CIVector(x: 12,y: 4), "inputBottomRight": CIVector(x: 756,y: 0)])
        let context = CIContext()
        let raster = try XCTUnwrap(context.createCGImage(warped, from: CGRect(x: 0,y: 0,width: 768,height: 512)))
        let output = folder.appendingPathComponent("perspective.tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL,"public.tiff" as CFString,1,nil))
        CGImageDestinationAddImage(destination,raster,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photos = [urls[0],output].enumerated().map { MobilePhoto(id: "perspective-\($0.offset)",name: $0.element.lastPathComponent,url: $0.element,rating: 0,width: 768,height: 512) }
        let plan = try await engine().analyze(photos,options: .init(),positions: [:],sensor: nil,
            registrationMode: .perspective,cancellation: .init(),progress: { _,_ in })
        XCTAssertEqual(plan.registrationMode,.perspective)
        let warps = try XCTUnwrap(plan.warps)
        XCTAssertEqual(warps.count,2)
        XCTAssertGreaterThan(abs(warps[1].values[1]) + abs(warps[1].values[3]),0.001)
        let packet = try PanoramaManifest(plan: plan).encoded()
        let manifest = try JSONDecoder().decode(PanoramaManifest.self,from: packet)
        XCTAssertEqual(manifest.registrationMode,.perspective)
        XCTAssertEqual(manifest.projection,"projective")
        let profile = try LCCProfileStore().load(LCCLensProfile.builtInID)
        XCTAssertThrowsError(try LCCCorrectionEngine.postProcess(scene: plan.sources[0],manifest: manifest,profile: profile)) {
            XCTAssertTrue($0.localizedDescription.contains("before perspective stitching"))
        }
    }

    func testShiftDraggingUsesPhysicalScaleAndCameraTravel() {
        let travel = PanoramaCameraBody.alpa12Max.travel(at: .degrees0)
        let moved = MobileShiftGeometry.dragged(.zero, translation: CGSize(width: 20,height: -10), pointsPerMM: 2, travel: travel)
        XCTAssertEqual(moved.x, 10); XCTAssertEqual(moved.y, 5)
        let clamped = MobileShiftGeometry.dragged(moved, translation: CGSize(width: 1000,height: -1000), pointsPerMM: 2, travel: travel)
        XCTAssertEqual(clamped, CGPoint(x: 18,y: 25))
        let rotated = PanoramaCameraBody.alpa12STC.travel(at: .degrees90)
        let vertical = MobileShiftGeometry.dragged(.zero, translation: CGSize(width: 20,height: -20), pointsPerMM: 2, travel: rotated)
        XCTAssertEqual(vertical.x, 0); XCTAssertEqual(vertical.y, 10)
    }

    func testCancellationDoesNotCreateOutput() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("samples"))
        _ = try await engine.importPhotos(urls, skipDuplicates: true, progress: { _,_ in })
        let photos = try await engine.photos(), cancellation = PanoramaCancellation(); cancellation.cancel()
        do {
            _ = try await engine.analyze(photos, options: .init(), positions: [:], sensor: nil,
                                         cancellation: cancellation, progress: { _,_ in })
            XCTFail("Cancelled alignment should throw")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Exports").path)) }
    }

    private func makeFlat(name: String, exposure: Float) throws -> URL {
        let width = 320, height = 240
        let neutral: [Double] = [0.4,1,0.65]
        let pattern = [0,1,3,2], gains: [Float] = [0.4,1,0.65,1]
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let dx = Float(x) / Float(width-1) - 0.5, dy = Float(y) / Float(height-1) - 0.5
            let falloff = Float(0.6) * exp(-1.6 * (dx*dx + dy*dy)) * exposure
            pixels[y*width+x] = falloff * gains[pattern[(y%2)*2+x%2]]
        } }
        let mosaic = CameraMosaic(width: width,height: height,samples: pixels,pattern: pattern,
            neutral: neutral,matrix: [0.6468,-0.1899,-0.0545,-0.4526,1.2267,0.2542,-0.0388,0.1276,0.6096])
        let data = mosaic.dng().data
        let url = folder.appendingPathComponent(name)
        try data.write(to: url); return url
    }
}
