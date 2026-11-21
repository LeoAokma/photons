import XCTest
import CoreImage
import ImageIO
import CryptoKit
import UIKit
import Metal
import PhotonsLocalization
import PhotonsCore
import PhotonsCatalog
import PhotonsPanorama
@testable import PhotonsMobile
@testable import PhotonsExtensions

final class IPadEngineTests: XCTestCase {
    @MainActor
    func testGuideSwipesRespectDirectionThresholdAndPageBounds() {
        let guide = MobileGuideController(); guide.start([.init("one"),.init("two"),.init("three")])
        guide.swipe(translation: CGSize(width: 180,height: 0)); XCTAssertEqual(guide.index,0)
        guide.swipe(translation: CGSize(width: -30,height: 0)); XCTAssertEqual(guide.index,0)
        guide.swipe(translation: CGSize(width: -60,height: 80)); XCTAssertEqual(guide.index,0)
        guide.swipe(translation: CGSize(width: -180,height: 30)); XCTAssertEqual(guide.index,1)
        guide.swipe(translation: CGSize(width: -800,height: 0)); XCTAssertEqual(guide.index,2)
        guide.swipe(translation: CGSize(width: -180,height: 0)); XCTAssertEqual(guide.index,2)
        guide.swipe(translation: CGSize(width: 180,height: 20)); XCTAssertEqual(guide.index,1)
        guide.close(); guide.swipe(translation: CGSize(width: -180,height: 0)); XCTAssertFalse(guide.active)
    }
    func testInterfaceLanguageRespectsPreferenceAndDeviceOrder() {
        XCTAssertEqual(L10n.resolveLanguage(preference: nil,preferredLanguages: ["zh-Hans-US","en-US"]),"zh-Hans")
        XCTAssertEqual(L10n.resolveLanguage(preference: "system",preferredLanguages: ["fr-FR","zh-Hant-TW","en"]),"zh-Hans")
        XCTAssertEqual(L10n.resolveLanguage(preference: "system",preferredLanguages: ["en-GB","zh-Hans"]),"en")
        XCTAssertEqual(L10n.resolveLanguage(preference: "en",preferredLanguages: ["zh-Hans"]),"en")
        XCTAssertEqual(L10n.resolveLanguage(preference: "zh-Hans",preferredLanguages: ["en"]),"zh-Hans")
        XCTAssertEqual(L10n.resolveLanguage(preference: nil,preferredLanguages: ["fr","de"]),"en")
        XCTAssertEqual(L10n.resolveLanguage(preference: nil,preferredLanguages: []),"en")
    }
    func testQuickStartCompletionIsPerBuildAndSurvivesRelaunch() {
        let suite = "guide-test-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MobileGuideHistory(defaults: defaults)
        XCTAssertFalse(first.hasSeen("0.1.0 (5)"))
        first.markSeen("0.1.0 (5)"); first.markSeen("0.1.0 (5)")
        let reopened = MobileGuideHistory(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(reopened.hasSeen("0.1.0 (5)")); XCTAssertFalse(reopened.hasSeen("0.1.0 (6)"))
        reopened.markSeen("0.1.0 (6)")
        XCTAssertTrue(reopened.hasSeen("0.1.0 (5)"),"Returning to a previously seen build should not replay automatically")
        XCTAssertFalse(reopened.hasSeen("0.2.0 (5)"),"Marketing versions distinguish reused build numbers")
    }
    @MainActor
    func testGuideGeometryFallbackNavigationAndDismissal() {
        let guide = MobileGuideController()
        let viewport = CGRect(x: 0,y: 40,width: 1000,height: 700)
        guide.register("toolbar",frame: CGRect(x: 0,y: 40,width: 1000,height: 58))
        guide.register("offscreen",frame: CGRect(x: 800,y: 900,width: 200,height: 80))
        var completions = 0
        guide.start([.init("one",target: "offscreen",fallback: "toolbar"),.init("two",target: "toolbar")]) { completions += 1 }
        XCTAssertEqual(guide.highlight(in: viewport),CGRect(x: 0,y: 0,width: 1000,height: 58))
        guide.previous(); XCTAssertEqual(guide.index,0)
        guide.next(); guide.next(); XCTAssertEqual(guide.index,1)
        let target = CGRect(x: 850,y: 20,width: 100,height: 50)
        let safe = CGRect(x: 16,y: 16,width: 968,height: 600)
        let card = MobileGuideLayout.cardArea(target: target,safe: safe)
        XCTAssertTrue(safe.contains(card)); XCTAssertFalse(card.intersects(target))
        guide.close(); guide.close(); XCTAssertFalse(guide.active); XCTAssertEqual(completions,1)
        XCTAssertEqual(MobileGuideLayout.cardArea(target: safe,safe: safe),safe)
    }

    func testDeghostToggleReusesRegisteredGeometry() async throws {
        let worker=engine(),urls=try MobileSamples.create(in:folder.appendingPathComponent("deghost"))
        let photos=urls.prefix(2).enumerated().map { MobilePhoto(id:"test-\($0.offset)",name:$0.element.lastPathComponent,url:$0.element,rating:0,width:768,height:512) }
        let plan=try await worker.analyze(photos,options:.init(),positions:[:],sensor:nil,cancellation:.init(),progress:{_,_ in})
        var options = plan.options
        options.avoidMotion = false
        let off = try await worker.updatePanorama(plan, options: options, cancellation: .init())
        XCTAssertFalse(off.options.avoidMotion);XCTAssertEqual(off.origins,plan.origins);XCTAssertEqual(off.size,plan.size)
        XCTAssertNotNil(off.preview)
        let on = try await worker.updatePanorama(off, options: plan.options, cancellation: .init())
        XCTAssertTrue(on.options.avoidMotion);XCTAssertEqual(on.origins,off.origins)
    }
    @MainActor
    func testCancelledRealignmentDoesNotAcceptAnOldPlan() async throws {
        let worker = engine()
        let urls = try MobileSamples.create(in: folder.appendingPathComponent("cancel-alignment"))
        let photos = urls.prefix(2).map { MobilePhoto(id: $0.lastPathComponent, name: $0.lastPathComponent,
            url: $0, rating: 0, width: 768, height: 512) }
        let original = try await worker.analyze(photos, options: .init(), positions: [:], sensor: nil,
            cancellation: .init(), progress: { _,_ in })
        let model = MobileWorkspaceModel(engine: worker)
        model.photos = photos
        model.selected = Set(photos.map(\.id))
        model.plan = original
        var accepted = false
        model.stitch(options: original.options, positions: [:], sensor: nil, registrationMode: .shift) { _ in
            accepted = true
        }
        model.cancel()
        for _ in 0..<400 where model.busy { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(model.busy)
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.plan?.origins, original.origins)
    }

    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }
    private func engine() -> MobileEngine { MobileEngine(libraryURL: folder.appendingPathComponent("Test.photonslibrary")) }

    func testDetailSizingAccountsForSourceTextureAndMemory() throws {
        let request = MobileDetailRequest(rect: CGRect(x: 0.4,y: 0.4,width: 0.15,height: 0.15),scale: 1)
        let large = ImageSize(width: 11664,height: 8750)
        let bounded = try MobileDetailSizing.plan(source: large,output: large,request: request,
            textureLimit: 8192,availableBytes: 64 * 1024 * 1024 * 1024)
        XCTAssertLessThan(bounded.scale,1); XCTAssertLessThan(bounded.longEdge,8192)
        XCTAssertEqual(bounded.request.rect.minX,request.rect.minX,accuracy: 1e-12)
        XCTAssertEqual(bounded.request.rect.minY,request.rect.minY,accuracy: 1e-12)
        XCTAssertEqual(bounded.request.rect.width,request.rect.width,accuracy: 1e-12)
        XCTAssertEqual(bounded.request.rect.height,request.rect.height,accuracy: 1e-12)
        let ordinary = ImageSize(width: 4000,height: 3000)
        let native = try MobileDetailSizing.plan(source: ordinary,output: ordinary,request: request,
            textureLimit: 16384,availableBytes: 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(native.scale,1,"Normal-size photos still receive real 1:1 detail")
        let constrained = try MobileDetailSizing.plan(source: ordinary,output: ordinary,request: request,
            textureLimit: 16384,availableBytes: 512 * 1024 * 1024)
        XCTAssertLessThan(constrained.scale,native.scale)
        XCTAssertThrowsError(try MobileDetailSizing.plan(source: large,output: large,request: request,
            textureLimit: 8192,availableBytes: 32 * 1024 * 1024))
        for bad in [MobileDetailRequest(rect: .zero,scale: 1),
                    MobileDetailRequest(rect: request.rect,scale: .nan),
                    MobileDetailRequest(rect: CGRect(x: 2,y: 2,width: 1,height: 1),scale: 1),
                    MobileDetailRequest(rect: CGRect(x: CGFloat.nan,y: 0,width: 1,height: 1),scale: 1)] {
            XCTAssertThrowsError(try MobileDetailSizing.plan(source: ordinary,output: ordinary,request: bad,
                textureLimit: 8192,availableBytes: 8 * 1024 * 1024 * 1024))
        }
    }

    func testBoundedDetailMatchesEditedPixelsAtItsDeclaredResolution() async throws {
        let engine = MobileEngine(libraryURL: folder.appendingPathComponent("Bounded.photonslibrary"),
                                  detailAvailableMemory: { 300 * 1024 * 1024 })
        let urls = try MobileSamples.create(in: folder.appendingPathComponent("bounded-pixels"))
        let photo = MobilePhoto(id: "bounded",name: "bounded",url: urls[0],rating: 0,width: 768,height: 512)
        var edit = EditModel.neutral
        edit.light.exposure = 0.6; edit.geometry.quarterTurns = 1
        edit.geometry.crop = .init(x: 0.125,y: 0.125,width: 0.75,height: 0.75)
        let request = MobileDetailRequest(rect: CGRect(x: 0.25,y: 0.25,width: 0.5,height: 0.5),scale: 1)
        let detail = try await engine.detail(photo,edit: edit,hdr: true,request: request)
        XCTAssertLessThan(detail.resolutionScale,1)
        let full = try await engine.frame(photo,edit: edit,hdr: true,edge: Int(768 * detail.resolutionScale))
        let crop = CGRect(x: Int((detail.rect.minX * Double(full.image.width)).rounded()),
                          y: Int((detail.rect.minY * Double(full.image.height)).rounded()),
                          width: detail.image.width,height: detail.image.height)
        let expected = try XCTUnwrap(full.image.cropping(to: crop))
        let actualData = try XCTUnwrap(detail.image.dataProvider?.data) as Data
        let expectedData = try XCTUnwrap(expected.dataProvider?.data) as Data
        // The padded halo is intentionally outside the viewport. Compare the visible
        // pixels, not the halo's own neighbourhood-clamped outer border.
        let x0 = max(0,Int(request.rect.minX * Double(full.image.width) - crop.minX))
        let y0 = max(0,Int(request.rect.minY * Double(full.image.height) - crop.minY))
        let x1 = min(detail.image.width,Int(request.rect.maxX * Double(full.image.width) - crop.minX))
        let y1 = min(detail.image.height,Int(request.rect.maxY * Double(full.image.height) - crop.minY))
        var delta = 0.0
        for y in y0..<y1 { for x in (x0 * 4)..<(x1 * 4) {
            let a = actualData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: y * detail.image.bytesPerRow + x * 2,as: UInt16.self) }
            let b = expectedData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: y * expected.bytesPerRow + x * 2,as: UInt16.self) }
            delta = max(delta,abs(Double(Float16(bitPattern: a)) - Double(Float16(bitPattern: b))))
        } }
        XCTAssertLessThan(delta,0.015,"Reduced-resolution details must preserve edits, crop, rotation and HDR pixels")
    }

    func testLowMemoryDetailDoesNotDecodeAndKeepsCachedPreview() async throws {
        let engine = MobileEngine(libraryURL: folder.appendingPathComponent("LowMemory.photonslibrary"),
                                  detailAvailableMemory: { 32 * 1024 * 1024 })
        let urls = try MobileSamples.create(in: folder.appendingPathComponent("low-memory"))
        let photo = MobilePhoto(id: "low",name: "low",url: urls[0],rating: 0,width: 768,height: 512)
        let preview = try await engine.frame(photo,edit: .neutral,hdr: true,edge: 320)
        let count = await engine.renderCount
        do {
            _ = try await engine.detail(photo,edit: .neutral,hdr: true,
                request: .init(rect: CGRect(x: 0.25,y: 0.25,width: 0.5,height: 0.5),scale: 1))
            XCTFail("Low memory should leave the existing preview in place")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let after = await engine.renderCount; XCTAssertEqual(count,after)
        let retained = try await engine.frame(photo,edit: .neutral,hdr: true,edge: 320)
        XCTAssertTrue(retained.image === preview.image)
    }

    @MainActor
    func testOptionalLargeRAWZoomRendersBoundedDetailsAndReusesDecode() async throws {
        let input = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0]
            .appendingPathComponent("ValidationInputs/628-633/B0000628.3FR")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Optional local 100 MP RAW fixture") }
        let engine = engine(), size = try ImageSourceDecoder.size(at: input)
        let photo = MobilePhoto(id: "large-raw",name: input.lastPathComponent,url: input,rating: 0,width: size.width,height: size.height)
        let preview = try await engine.frame(photo,edit: .neutral,hdr: true,edge: 1200)
        let request = MobileDetailRequest(rect: CGRect(x: 0.4,y: 0.4,width: 0.15,height: 0.15),scale: 1)
        let detail = try await engine.detail(photo,edit: .neutral,hdr: true,request: request)
        XCTAssertGreaterThan(detail.image.width,Int(Double(preview.image.width) * request.rect.width))
        XCTAssertLessThan(detail.resolutionScale,1)
        XCTAssertGreaterThan(detail.resolutionScale,0.1)
        XCTAssertTrue(detail.rect.contains(request.rect))
        let before = await engine.renderCount
        let decodeScale = Float(Int(Double(max(size.width,size.height)) * detail.resolutionScale)) / Float(max(size.width,size.height))
        let decodes = RAWDecoder.decodeCounts()[decodeScale,default: 0]
        let sdr = try await engine.detail(photo,edit: .neutral,hdr: false,request: request)
        let again = try await engine.detail(photo,edit: .neutral,hdr: true,request: request)
        XCTAssertTrue(detail.image === again.image); XCTAssertEqual(sdr.rect,detail.rect)
        let after = await engine.renderCount; XCTAssertEqual(after,before)
        let moved = MobileDetailRequest(rect: CGRect(x: 0.45,y: 0.4,width: 0.15,height: 0.15),scale: 1)
        _ = try await engine.detail(photo,edit: .neutral,hdr: true,request: moved)
        // The host app may warm small thumbnails concurrently; only this detail rung
        // belongs to the full-detail decode whose reuse is being checked.
        XCTAssertEqual(RAWDecoder.decodeCounts()[decodeScale,default: 0],decodes,"Panning should reuse the bounded source decode")
        let model = MobileWorkspaceModel(engine: engine)
        model.hdr = true; model.active = photo; model.frame = preview
        model.requestDetail(request)
        for _ in 0..<300 where model.detailFrame == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(model.detailFrame)
        XCTAssertTrue(model.detailStatus.contains("50%"),model.detailStatus)
        XCTAssertNil(model.error); XCTAssertTrue(model.frame?.image === preview.image)
        model.requestDetail(nil)
        XCTAssertNil(model.detailFrame); XCTAssertTrue(model.detailStatus.isEmpty)
        print("100 MP RAW detail: scale \(detail.resolutionScale), patch \(detail.image.width) × \(detail.image.height), HDR/SDR and pan checked")
    }

    func testOptionalOversizedRAWThrowsBeforeMetalAllocation() throws {
        let input = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0]
            .appendingPathComponent("ValidationInputs/628-633/B0000628.3FR")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Optional local 100 MP RAW fixture") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = try ImageSourceDecoder.size(at: input)
        guard max(size.width,size.height) > MetalTextureLimits.maximum2DDimension(for: device) else {
            throw XCTSkip("This device supports the original source dimensions")
        }
        XCTAssertThrowsError(try RAWDecoder().decodeDetailed(input)) { error in
            guard let dimensions = error as? TextureDimensionError else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertGreaterThan(max(dimensions.width,dimensions.height),dimensions.maximum)
            print("RAW descriptor safely rejected: \(dimensions.width) × \(dimensions.height), limit \(dimensions.maximum)")
        }
    }

    func testLensProfileDetailsPreserveCaptureMetadataAndCoverage() async throws {
        let engine = engine(), profiles = try await engine.profiles()
        let summary = try XCTUnwrap(profiles.first { $0.id == LCCLensProfile.builtInID })
        let profile = try await engine.profile(summary.id)
        try profile.validate()
        XCTAssertEqual(summary.captureCount,profile.captures.count)
        XCTAssertFalse(profile.notes.isEmpty); XCTAssertNotNil(LCCProfileSummary(profile).calibrationBody)
        for orientation in profile.orientations {
            let captures = profile.captures(for: orientation), bounds = MobileProfileCoverage.bounds(profile.captures(for: orientation))
            XCTAssertFalse(bounds.isNull)
            for capture in captures { XCTAssertTrue(bounds.contains(capture.fieldRect)); XCTAssertGreaterThan(capture.grid.width,1); XCTAssertGreaterThan(capture.pixelWidth,0) }
        }
    }

    func testClearCacheKeepsLibraryOriginalsEditsFoldersAndProfiles() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("clear-cache"))
        let group = try await engine.createFolder("Keep")
        _ = try await engine.importPhotos(urls,skipDuplicates: true,folder: group.id,progress: { _,_ in })
        let photos = try await engine.photos(), photo = try XCTUnwrap(photos.first)
        let original = try Data(contentsOf: photo.url)
        var edit = EditModel.neutral; edit.light.exposure = 0.8
        try await engine.save(edit,history: .init(baseline: edit),id: photo.id)
        let profiles = try await engine.profiles()
        let export = folder.appendingPathComponent("Test.photonslibrary/Exports/keep.txt")
        try FileManager.default.createDirectory(at: export.deletingLastPathComponent(),withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: export)
        _ = try await engine.frame(photo,edit: edit,hdr: true)
        let before = try await engine.cacheUsage(); XCTAssertGreaterThan(before.diskBytes,0); XCTAssertGreaterThan(before.memoryBytes,0)
        try await engine.clearPreviewCache()
        let after = try await engine.cacheUsage(); XCTAssertEqual(after.diskBytes,0); XCTAssertEqual(after.memoryBytes,0); XCTAssertEqual(after.files,0)
        XCTAssertEqual(try Data(contentsOf: photo.url),original); XCTAssertEqual(try Data(contentsOf: export),Data("keep".utf8))
        let stored = try await engine.edit(photo.id), folders = try await engine.folderIndex(), remainingProfiles = try await engine.profiles()
        XCTAssertEqual(stored.light.exposure,0.8); XCTAssertEqual(folders.assignments[photo.id],group.id); XCTAssertEqual(profiles,remainingProfiles)
        let count = await engine.renderCount
        _ = try await engine.frame(photo,edit: edit,hdr: true)
        let regenerated = await engine.renderCount; XCTAssertEqual(regenerated,count+1)
    }

    func testPairedPreviewCacheSurvivesToggleRestartAndInvalidatesEdits() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("cache"))
        let photo = MobilePhoto(id: "cache",name: "cache",url: urls[0],rating: 0,width: 768,height: 512)
        var edit = EditModel.neutral; edit.light.exposure = 2
        let hdr = try await engine.frame(photo,edit: edit,hdr: true)
        let count = await engine.renderCount
        let sdr = try await engine.frame(photo,edit: edit,hdr: false)
        let again = try await engine.frame(photo,edit: edit,hdr: true)
        let afterToggle = await engine.renderCount
        XCTAssertEqual(count,afterToggle); XCTAssertTrue(again.image === hdr.image)
        XCTAssertNotEqual(hdr.histogram?.binsDigest(),sdr.histogram?.binsDigest())
        for i in 0..<8 { var e = edit; e.light.exposure = Double(i)/10; _ = try await engine.frame(photo,edit: e,hdr: false,edge: 320) }
        let afterWarming = await engine.renderCount
        _ = try await engine.frame(photo,edit: edit,hdr: false)
        let afterFull = await engine.renderCount; XCTAssertEqual(afterWarming,afterFull)
        let reopened = self.engine()
        let disk = try await reopened.frame(photo,edit: edit,hdr: true)
        let diskCount = await reopened.renderCount
        XCTAssertEqual(diskCount,0); XCTAssertEqual(disk.histogram,hdr.histogram)
        XCTAssertEqual(disk.image.dataProvider?.data,hdr.image.dataProvider?.data)
        edit.light.exposure = 2.5
        _ = try await reopened.frame(photo,edit: edit,hdr: false)
        let editedCount = await reopened.renderCount; XCTAssertEqual(editedCount,1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)],ofItemAtPath: photo.url.path)
        _ = try await reopened.frame(photo,edit: edit,hdr: true)
        let replacedCount = await reopened.renderCount; XCTAssertEqual(replacedCount,2)
        let request = MobileDetailRequest(rect: CGRect(x: 0.2,y: 0.2,width: 0.4,height: 0.4),scale: 1)
        let detail = try await reopened.detail(photo,edit: edit,hdr: true,request: request)
        let beforeDetailToggle = await reopened.renderCount
        let detailSDR = try await reopened.detail(photo,edit: edit,hdr: false,request: request)
        let afterDetailToggle = await reopened.renderCount
        XCTAssertEqual(beforeDetailToggle,afterDetailToggle); XCTAssertEqual(detail.rect,detailSDR.rect)
        var memory = MobilePreviewMemoryCache(budget: 2*(hdr.image.bytesPerRow*hdr.image.height+sdr.image.bytesPerRow*sdr.image.height))
        let pair = MobilePreviewPair(hdr: hdr,sdr: sdr)
        memory.put(pair,key: "a"); memory.put(pair,key: "b"); _ = memory.get("a"); memory.put(pair,key: "c")
        XCTAssertNil(memory.get("b")); XCTAssertNotNil(memory.get("a")); XCTAssertLessThanOrEqual(memory.bytes,memory.budget)
        let directory = folder.appendingPathComponent("Test.photonslibrary/MobilePreviews")
        for url in try FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: nil) { try Data("broken".utf8).write(to: url) }
        let corruptReader = self.engine()
        _ = try await corruptReader.frame(photo,edit: edit,hdr: false)
        let fallbackCount = await corruptReader.renderCount; XCTAssertEqual(fallbackCount,1)
    }

    func testLegacyPreviewIsRegeneratedAfterEngineUpgrade() async throws {
        let producer = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("upgrade"))
        let photo = MobilePhoto(id: "upgrade",name: "upgrade",url: urls[0],rating: 0,width: 768,height: 512)
        let edit = EditModel.neutral
        _ = try await producer.frame(photo,edit: edit,hdr: true)
        let directory = folder.appendingPathComponent("Test.photonslibrary/MobilePreviews")
        let records = try FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: nil)
        XCTAssertEqual(records.count,1)
        let record = try XCTUnwrap(records.first)
        // Re-create the actual pre-upgrade disk filename, with a valid pair payload. An app
        // upgrade must miss this entry rather than accept obsolete but decodable pixels.
        let attributes = try FileManager.default.attributesOfItem(atPath: photo.url.path)
        let source = "\(photo.url.path):\((attributes[.size] as? NSNumber)?.int64Value ?? 0):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let legacy = SHA256.hash(data: Data("ipad-v3-pair:\(photo.id):\(source):1600:".utf8) + (try encoder.encode(edit)))
            .map { String(format: "%02x",$0) }.joined()
        let oldURL = directory.appendingPathComponent(legacy + ".pair")
        try FileManager.default.moveItem(at: record,to: oldURL)
        let upgraded = engine()
        _ = try await upgraded.frame(photo,edit: edit,hdr: false)
        let renders = await upgraded.renderCount
        XCTAssertEqual(renders,1,"An old algorithm's preview must be regenerated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path),"Disposable old entries remain under normal size pruning")
        let reopened = engine()
        _ = try await reopened.frame(photo,edit: edit,hdr: true)
        let reused = await reopened.renderCount
        XCTAssertEqual(reused,0,"Current-generation pairs remain reusable across launches and HDR/SDR")
    }

    func testPanoramaDisplayModeReusesCompositePreview() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("pano-cache"))
        let photos = urls.map { MobilePhoto(id: $0.lastPathComponent,name: $0.lastPathComponent,url: $0,rating: 0,width: 768,height: 512) }
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,cancellation: .init(),progress: { _,_ in })
        let first = try await engine.frame(plan,hdr: true)
        _ = try await engine.frame(plan,hdr: false)
        let again = try await engine.frame(plan,hdr: true)
        let count = await engine.panoramaPreviewCount
        XCTAssertEqual(count,1); XCTAssertTrue(first.image === again.image)
    }

    func testHistogramAdditiveBandsAndPixelCoverageKeepNeutralPeaks() {
        let bands = MobileHistogramReading.bands(tops: [20,40,60],bottom: 100)
        XCTAssertEqual(bands.map(\.mask),[7,3,1]) // white, yellow, red; no channel exceeds 1.
        XCTAssertEqual(bands.map(\.height),[40,20,20])
        let neutral = MobileHistogramReading.bands(tops: [25,25,25],bottom: 100).filter { $0.height > 0 }
        XCTAssertEqual(neutral.count,1); XCTAssertEqual(neutral.first?.mask,7)
        let points = [CGPoint(x: 0,y: 100),CGPoint(x: 0.5,y: 10),CGPoint(x: 1,y: 100)]
        var cursor = 0
        XCTAssertEqual(MobileHistogramReading.top(points,from: 0.2,to: 0.8,cursor: &cursor),10)
        XCTAssertEqual(MobileHistogramReading.top(points,from: 0.8,to: 1,cursor: &cursor),64,accuracy: 0.0001)
        XCTAssertTrue(MobileHistogramReading.bin(at: 0.75).tail,"HDR/SDR use the same fixed axis")
    }

    func testHistogramAxisAndDisplayClippingMatchMacSemantics() throws {
        XCTAssertEqual(MobileHistogramReading.bin(at: 0.25).index,128)
        XCTAssertTrue(MobileHistogramReading.bin(at: 0.5).tail)
        XCTAssertEqual(MobileHistogramReading.bin(at: 0.75).index,128)
        XCTAssertEqual(MobileHistogramReading.bin(at: 1).index,255)
        let sample = LinearSample(width: 3,height: 1,rgba: [0,0,0,1, 1,1,1,1, 4,4,4,1])
        let histogram = HistogramSnapshot(sample: sample,canvas: ImageSize(width: 300,height: 100)).hdr
        XCTAssertEqual(histogram.luma.clippedLow,1.0/3,accuracy: 0.001)
        XCTAssertGreaterThan(histogram.withDisplayHeadroom(1).luma.clippedCeiling,histogram.withDisplayHeadroom(8).luma.clippedCeiling)
        XCTAssertEqual(histogram.withDisplayHeadroom(1).binsDigest(),histogram.withDisplayHeadroom(8).binsDigest())
        XCTAssertEqual(MobileHistogramReading.percent(0.0001),"<0.1%")
    }

    func testSingleLibraryFoldersPersistWithoutChangingOriginalsOrEdits() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("folder-samples"))
        let first = try await engine.createFolder("Travel"), second = try await engine.createFolder("Studio")
        _ = try await engine.importPhotos(urls,skipDuplicates: true,folder: first.id,progress: { _,_ in })
        let photos = try await engine.photos(), photo = try XCTUnwrap(photos.first)
        let original = try Data(contentsOf: photo.url)
        var edit = EditModel.neutral; edit.light.exposure = 0.7
        try await engine.save(edit,history: .init(baseline: edit),id: photo.id)
        try await engine.movePhotos([photo.id],to: second.id)
        try await engine.renameFolder(second.id,to: "Portraits")
        let reopened = self.engine(), index = try await reopened.folderIndex()
        XCTAssertEqual(index.assignments[photo.id],second.id)
        XCTAssertEqual(index.folders.first { $0.id == second.id }?.name,"Portraits")
        XCTAssertEqual(index.assignments.count,3)
        try await reopened.removeFolder(second.id)
        let removed = try await reopened.folderIndex(), saved = try await reopened.edit(photo.id)
        XCTAssertNil(removed.assignments[photo.id]); XCTAssertEqual(saved.light.exposure,0.7)
        XCTAssertEqual(try Data(contentsOf: photo.url),original)
        do { _ = try await engine.createFolder(" travel "); XCTFail("Duplicate names must be rejected") } catch { }
        do { _ = try await engine.importPhotos([folder.appendingPathComponent("Other.photonslibrary")],skipDuplicates: true,progress: { _,_ in }); XCTFail("Must not import another library") } catch { }
        let remaining = try await reopened.photos(); XCTAssertEqual(remaining.count,3)
    }

    func testZoomDetailMatchesEditedFullResolutionPixels() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("detail-samples"))
        let photo = MobilePhoto(id: "detail",name: "detail",url: urls[0],rating: 0,width: 768,height: 512)
        var edit = EditModel.neutral
        edit.light.exposure = 0.6; edit.geometry.quarterTurns = 1
        edit.geometry.crop = .init(x: 0.125,y: 0.125,width: 0.75,height: 0.75)
        let full = try await engine.frame(photo,edit: edit,hdr: true,edge: 0)
        let request = MobileDetailRequest(rect: CGRect(x: 0.25,y: 0.25,width: 0.5,height: 0.5),scale: 1)
        let detail = try await engine.detail(photo,edit: edit,hdr: true,request: request)
        let rect = CGRect(x: detail.rect.minX*Double(full.image.width),y: detail.rect.minY*Double(full.image.height),width: Double(detail.image.width),height: Double(detail.image.height))
        let expected = try XCTUnwrap(full.image.cropping(to: rect))
        let actualData = try XCTUnwrap(detail.image.dataProvider?.data) as Data
        let expectedData = try XCTUnwrap(expected.dataProvider?.data) as Data
        var largest = 0.0
        let x0 = Int(request.rect.minX * Double(full.image.width) - rect.minX)
        let y0 = Int(request.rect.minY * Double(full.image.height) - rect.minY)
        let x1 = min(detail.image.width,Int(request.rect.maxX * Double(full.image.width) - rect.minX))
        let y1 = min(detail.image.height,Int(request.rect.maxY * Double(full.image.height) - rect.minY))
        for y in y0..<y1 {
            for x in (x0*4)..<(x1*4) {
                let a = actualData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: y*detail.image.bytesPerRow+x*2,as: UInt16.self) }
                let b = expectedData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: y*expected.bytesPerRow+x*2,as: UInt16.self) }
                largest = max(largest,abs(Double(Float16(bitPattern: a))-Double(Float16(bitPattern: b))))
            }
        }
        XCTAssertLessThan(largest,0.015,"Zoom must render the same edited pixels, including crop and rotation, not rescale the fit preview")
        XCTAssertLessThan(detail.image.width,full.image.width)
        XCTAssertEqual(MobileZoomGeometry.fit(pixels: CGSize(width: 4000,height: 3000),viewport: CGSize(width: 1000,height: 750),screenScale: 2),0.5)
        XCTAssertNil(MobileZoomGeometry.validPercent("nan")); XCTAssertNil(MobileZoomGeometry.validPercent("0"))
        XCTAssertEqual(MobileZoomGeometry.validPercent("150"),1.5)
    }

    @MainActor
    func testPanoramaDismissalPreservesVisibleThumbnailsAndRecoversEvictedOnes() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("thumbnail-lifecycle"))
        _ = try await engine.importPhotos(urls,skipDuplicates: true,progress: { _,_ in })
        let photos = try await engine.photos(), model = MobileWorkspaceModel(engine: engine)
        let first = photos[0], second = photos[1], third = photos[2]
        model.hdr = true
        model.thumbnailVisibility(first.id,visible: true); model.thumbnailVisibility(second.id,visible: true)
        await model.start()
        for _ in 0..<200 where model.thumbnails[first.id] == nil || model.thumbnails[second.id] == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        let original = try XCTUnwrap(model.thumbnails[first.id]), other = try XCTUnwrap(model.thumbnails[second.id])
        // Simulate a recently scrolled-off cell, already persisted to the disk cache.
        model.thumbnails[third.id] = try await engine.thumbnail(third,hdr: true)
        let before = await engine.renderCount
        model.beginPanorama()
        model.thumbnailVisibility(first.id,visible: false); model.thumbnailVisibility(second.id,visible: false)
        model.showGrid = false
        model.memoryWarning()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.thumbnails[first.id]?.image === original.image)
        XCTAssertTrue(model.thumbnails[second.id]?.image === other.image)
        XCTAssertNil(model.thumbnails[third.id],"Offscreen thumbnails should be evicted under pressure")
        model.endPanorama()
        XCTAssertTrue(model.showGrid)
        XCTAssertTrue(model.thumbnails[first.id]?.image === original.image)
        // A job cancels the queued load; completion must restart missing thumbnails.
        model.thumbnailVisibility(third.id,visible: true)
        model.importPhotos(urls)
        for _ in 0..<200 where model.busy || model.thumbnails[third.id] == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.thumbnails[third.id]); XCTAssertNil(model.error)
        let recovered = await engine.renderCount
        XCTAssertEqual(recovered,before,"Recovery must use persisted previews, not redevelop unchanged sources")
        await model.start() // Root .task restart is harmless.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.thumbnails[first.id]?.image === original.image)
        // HDR/SDR changes refresh only the display variant, retaining disk/RAW reuse.
        model.toggleHDR()
        for _ in 0..<200 where model.thumbnails[first.id]?.image === original.image {
            try await Task.sleep(for: .milliseconds(25))
        }
        let expected = try await engine.thumbnail(first,hdr: false)
        XCTAssertTrue(model.thumbnails[first.id]?.image === expected.image)
        let afterToggle = await engine.renderCount; XCTAssertEqual(afterToggle,before)
    }

    @MainActor
    func testMemoryPressureRestartsMissingVisibleThumbnailsWithoutPanorama() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("thumbnail-pressure"))
        _ = try await engine.importPhotos(urls,skipDuplicates: true,progress: { _,_ in })
        let photos = try await engine.photos()
        let model = MobileWorkspaceModel(engine: engine), photo = try XCTUnwrap(photos.first)
        model.thumbnailVisibility(photo.id,visible: true)
        await model.start()
        // Cancel the coalesced first load before it runs, just as a memory warning can.
        model.memoryWarning()
        for _ in 0..<200 where model.thumbnails[photo.id] == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(model.thumbnails[photo.id]); XCTAssertNil(model.error)
    }

    @MainActor
    func testMultiSelectionDoesNotLoadOrReplaceTheActiveEditor() async throws {
        let model = MobileWorkspaceModel()
        let first = MobilePhoto(id: "first",name: "first",url: folder.appendingPathComponent("missing-first.tiff"),rating: 0,width: 768,height: 512)
        let second = MobilePhoto(id: "second",name: "second",url: folder.appendingPathComponent("missing-second.tiff"),rating: 0,width: 768,height: 512)
        model.active = first; model.selected = [first.id]
        model.edit.light.exposure = 0.7
        for _ in 0..<20 {
            model.toggleSelection(second)
            XCTAssertTrue(model.selected.contains(second.id))
            model.toggleSelection(second)
            XCTAssertFalse(model.selected.contains(second.id))
        }
        XCTAssertEqual(model.selected,[first.id]); XCTAssertEqual(model.active?.id,first.id)
        XCTAssertEqual(model.edit.light.exposure,0.7); XCTAssertFalse(model.selectionLoading)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(model.error); XCTAssertEqual(model.active?.id,first.id)
        XCTAssertEqual(model.edit.light.exposure,0.7)
    }

    func testGridTapSequenceActsOnFirstTapAndKeepsDoubleTapOnSamePhoto() {
        var sequence = MobileGridTapSequence()
        XCTAssertEqual(sequence.action(photoID: "a",tapCount: 1,selectionMode: false),.select)
        XCTAssertEqual(sequence.action(photoID: "a",tapCount: 2,selectionMode: false),.open)
        // Rapid taps on different cells must select, not accidentally open the second cell.
        XCTAssertEqual(sequence.action(photoID: "a",tapCount: 1,selectionMode: false),.select)
        XCTAssertEqual(sequence.action(photoID: "b",tapCount: 2,selectionMode: false),.select)
        XCTAssertEqual(sequence.action(photoID: "a",tapCount: 3,selectionMode: false),.select)
        XCTAssertEqual(sequence.action(photoID: "a",tapCount: 1,selectionMode: false),.select)
        // Every tap remains an independent checkbox action while multi-selecting.
        XCTAssertEqual(sequence.action(photoID: "a",tapCount: 1,selectionMode: true),.toggleSelection)
        XCTAssertEqual(sequence.action(photoID: "a",tapCount: 2,selectionMode: true),.toggleSelection)
        XCTAssertEqual(sequence.action(photoID: "a",tapCount: 2,selectionMode: false),.select)
    }

    @MainActor
    func testPanoramaZoomKeepsLowResolutionPreviewWithoutReadingSources() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("preview-only"))
        let photos = urls.map { MobilePhoto(id: $0.lastPathComponent,name: $0.lastPathComponent,url: $0,rating: 0,width: 768,height: 512) }
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,cancellation: .init(),progress: { _,_ in })
        let model = MobileWorkspaceModel()
        model.plan = plan; model.frame = try await engine.frame(plan,hdr: false)
        let preview = model.frame?.image
        // Missing originals would fail any attempted detail decode or composite.
        for url in urls { try FileManager.default.removeItem(at: url) }
        model.requestDetail(.init(rect: CGRect(x: 0.25,y: 0.25,width: 0.5,height: 0.5),scale: 1))
        XCTAssertFalse(model.detailStatus.isEmpty)
        let notice = model.detailStatus
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.detailStatus,notice)
        XCTAssertNil(model.detailFrame); XCTAssertNil(model.error)
        XCTAssertTrue(model.frame?.image === preview)
        model.requestDetail(nil)
        XCTAssertEqual(model.detailStatus,"")
    }

    @MainActor
    func testClosingPanoramaDiscardsTransientPreviewAndRestoresView() async throws {
        let model = MobileWorkspaceModel()
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("close-samples"))
        let photos = urls.map { MobilePhoto(id: $0.lastPathComponent,name: $0.lastPathComponent,url: $0,rating: 0,width: 768,height: 512) }
        let original = try await engine.frame(photos[0],edit: .neutral,hdr: false,edge: 256)
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,cancellation: .init(),progress: { _,_ in })
        model.active = photos[0]; model.thumbnails[photos[0].id] = original
        model.beginPanorama(); model.plan = plan; model.showGrid = false
        model.frame = try await engine.frame(plan,hdr: false)
        model.setPanoramaTone(.panoramaDefault) // pending asynchronous preview must not resurrect it
        model.endPanorama()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(model.plan); XCTAssertNil(model.manifest)
        XCTAssertTrue(model.showGrid)
        XCTAssertTrue(model.frame?.image === original.image)
        XCTAssertFalse(model.rendering)
        model.endPanorama() // repeated dismissal is harmless
        XCTAssertTrue(model.showGrid)
    }

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

    func testDNGCatalogUsesFullSizeAndRepairsLegacyPreviewDimensions() async throws {
        let url = folder.appendingPathComponent("panorama-6000.DNG")
        let image = CIImage(color: CIColor(red: 0.2,green: 0.4,blue: 0.6))
            .cropped(to: CGRect(x: 0,y: 0,width: 6000,height: 4304))
        try LinearDNGWriter.write(image: image,context: CIContext(options: [.cacheIntermediates: false]),to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,512)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,367)
        let metadata = try MetadataReader.read(url)
        XCTAssertEqual(metadata.width,6000); XCTAssertEqual(metadata.height,4304)

        let engine = engine()
        _ = try await engine.importPhotos([url],skipDuplicates: true,progress: { _,_ in })
        let imported = try await engine.photos()
        let photo = try XCTUnwrap(imported.first)
        XCTAssertEqual(photo.width,6000); XCTAssertEqual(photo.height,4304)
        var edit = EditModel.neutral; edit.light.exposure = 0.7
        var history = EditHistory(baseline: .neutral)
        history.commit(edit,label: "Exposure",coalesce: false)
        try await engine.save(edit,history: history,id: photo.id)
        let catalog = try Catalog.open(at: folder.appendingPathComponent("Test.photonslibrary"))
        try catalog.setRating(4,forAsset: photo.id)
        // Simulate an existing library written by the old IFD0-only reader.
        try await catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET width = 512, height = 367 WHERE id = ?",arguments: [photo.id])
        }
        let before = try XCTUnwrap(catalog.asset(id: photo.id))
        let sourceHash = try FileHasher.sha256(of: photo.url)
        let reopened = self.engine()
        let corrected = try await reopened.photos()
        XCTAssertEqual(corrected.count,1); XCTAssertEqual(corrected[0].id,photo.id)
        XCTAssertEqual(corrected[0].width,6000); XCTAssertEqual(corrected[0].height,4304)
        let after = try XCTUnwrap(catalog.asset(id: photo.id))
        XCTAssertEqual(after.width,6000); XCTAssertEqual(after.height,4304)
        XCTAssertEqual(after.rating,4); XCTAssertEqual(after.contentHash,before.contentHash)
        XCTAssertEqual(after.developJson,before.developJson); XCTAssertEqual(after.historyEnd,before.historyEnd)
        XCTAssertEqual(after.editTime,before.editTime); XCTAssertEqual(after.renderVersion,before.renderVersion)
        XCTAssertEqual(try FileHasher.sha256(of: photo.url),sourceHash)
        var savedHistory = try await reopened.history(photo.id)
        XCTAssertEqual(savedHistory.undo()?.light.exposure,0)
        let renderCount = await reopened.renderCount
        XCTAssertEqual(renderCount,0,"Dimension repair must not render photos or invalidate preview caches")
        XCTAssertEqual(try catalog.repairDNGPreviewDimensions(),0,"Repair must be idempotent")
    }

    func testDNGDimensionRepairSkipsMissingSourcesAndSmallImages() async throws {
        let library = folder.appendingPathComponent("Test.photonslibrary")
        let catalog = try Catalog.create(at: library)
        for (name,width,height) in [("portrait",400,600),("small",96,64)] {
            let url = folder.appendingPathComponent(name + ".dng")
            let image = CIImage(color: CIColor(red: 0.3,green: 0.4,blue: 0.5))
                .cropped(to: CGRect(x: 0,y: 0,width: width,height: height))
            try LinearDNGWriter.write(image: image,context: CIContext(options: [.cacheIntermediates: false]),to: url)
            let summary = try ImportService(catalog: catalog).run(sources: [url],options: .init(mode: .reference))
            let id = try XCTUnwrap(summary.addedAssetIDs.first)
            let asset = try XCTUnwrap(catalog.asset(id: id))
            XCTAssertEqual(asset.width,width); XCTAssertEqual(asset.height,height)
            if name == "portrait" {
                try await catalog.dbQueue.write { db in
                    try db.execute(sql: "UPDATE assets SET width = 341, height = 512 WHERE id = ?",arguments: [id])
                }
                let holding = url.appendingPathExtension("offline")
                try FileManager.default.moveItem(at: url,to: holding)
                XCTAssertEqual(try catalog.repairDNGPreviewDimensions(),0)
                XCTAssertEqual(try catalog.asset(id: id)?.width,341)
                try FileManager.default.moveItem(at: holding,to: url)
                XCTAssertEqual(try catalog.repairDNGPreviewDimensions(),1)
                XCTAssertEqual(try catalog.asset(id: id)?.width,400)
                XCTAssertEqual(try catalog.asset(id: id)?.height,600)
            }
        }
        XCTAssertEqual(try catalog.repairDNGPreviewDimensions(),0)
        XCTAssertEqual(try catalog.assets().first { $0.filename == "small.dng" }?.width,96)
    }

    func testTIFFCompressionOnPhotoExport() async throws {
        let worker = engine()
        let urls = try MobileSamples.create(in: folder.appendingPathComponent("tiff-input"))
        _ = try await worker.importPhotos([urls[0]], skipDuplicates: true, progress: { _, _ in })
        let photos = try await worker.photos()
        let photo = try XCTUnwrap(photos.first)
        var settings = MobileExportSettings()
        settings.format = "tiff"
        settings.hdr = false
        settings.longEdge = 160
        XCTAssertEqual(settings.tiffCompression, .zip)
        let cases: [(TIFFCompression, Int, Int)] = [(.zip, 16, 8), (.lzw, 16, 5), (.uncompressed, 8, 1), (.jpeg, 8, 7)]
        for (mode, depth, tag) in cases {
            settings.tiffCompression = mode
            settings.tiffBitDepth = depth
            XCTAssertTrue(settings.tiffChoices(sourceLongEdge: photo.width).contains(mode))
            let output = try await worker.export(photo: photo, edit: .neutral, plan: nil, manifest: nil,
                                                 settings: settings, cancellation: .init(), progress: { _, _ in })
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            XCTAssertEqual(tiff[kCGImagePropertyTIFFCompression] as? Int, tag)
            XCTAssertTrue((props[kCGImagePropertyProfileName] as? String)?.contains("2020") == true, "\(props)")
            XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, depth)
        }
    }

    @MainActor
    func testLowBudgetPanoramaKeepsPlanAndCanRetryExport() async throws {
        let engine = MobileEngine(libraryURL: folder.appendingPathComponent("Test.photonslibrary"),
                                  exportMemoryBudget: { 264_000_000 })
        let urls = try MobileSamples.create(in: folder.appendingPathComponent("budget-input"))
        _ = try await engine.importPhotos(urls, skipDuplicates: true, progress: { _,_ in })
        let photos = try await engine.photos()
        let plan = try await engine.analyze(photos, options: .init(), positions: [:], sensor: nil,
                                            cancellation: .init(), progress: { _,_ in })
        let model = MobileWorkspaceModel(engine: engine)
        model.beginPanorama()
        model.plan = plan
        for format in ["dng", "tiff"] {
            var settings = MobileExportSettings()
            settings.format = format
            settings.longEdge = 0
            let failed = expectation(description: "Full-size budget failure: " + format)
            model.export(settings, onFailure: { message in
                XCTAssertTrue(message.contains("MB"))
                failed.fulfill()
            }, onSaved: { XCTFail("Failed export dismissed the workspace") })
            await fulfillment(of: [failed], timeout: 15)
            XCTAssertNotNil(model.plan)
            settings.longEdge = 128
            let saved = expectation(description: "Scaled retry: " + format)
            model.export(settings, onFailure: { XCTFail($0) }, onSaved: { saved.fulfill() })
            await fulfillment(of: [saved], timeout: 30)
            let output = try XCTUnwrap(model.output)
            XCTAssertEqual(try PanoramaSource(url: output).size.width, 128, accuracy: 1)
        }
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
        settings.longEdge = 0
        let full = try await engine.export(photo: nil,edit: .neutral,plan: plan,manifest: nil,settings: settings,cancellation: .init(),progress: { _,_ in })
        XCTAssertEqual(try PanoramaSource(url: full).size,plan.outputSize,"Full resolution must not silently retain a long-edge cap")
        let imported = try await engine.photos()
        XCTAssertEqual(imported.count, 5)
        let frame = try await engine.frame(plan, hdr: false)
        XCTAssertNotNil(frame.histogram)
        // A resized/cropped ordinary export of a reimported DNG must keep its original stitch geometry.
        let reimported = try XCTUnwrap(imported.first { $0.name == output.lastPathComponent })
        XCTAssertEqual(reimported.width,604); XCTAssertEqual(reimported.height,256)
        let fullPhoto = try XCTUnwrap(imported.first { $0.name == full.lastPathComponent })
        XCTAssertEqual(fullPhoto.width,Int(plan.outputSize.width))
        XCTAssertEqual(fullPhoto.height,Int(plan.outputSize.height))
        var cropEdit = EditModel.neutral; cropEdit.geometry.crop = .init(x: 0.25,y: 0.125,width: 0.5,height: 0.75)
        settings.format = "tiff"; settings.hdr = false; settings.longEdge = 160
        let copy = try await engine.export(photo: reimported,edit: cropEdit,plan: nil,manifest: nil,settings: settings,
                                          cancellation: .init(),progress: { _,_ in })
        let carried = try XCTUnwrap(PanoramaManifest.read(from: copy))
        XCTAssertEqual(carried.frames.count,3)
        let point = carried.canvasPoint(u: 0.25,v: 0.5)
        XCTAssertEqual(point.x,0.375,accuracy: 1e-8); XCTAssertEqual(point.y,0.5,accuracy: 1e-8)
    }

    func testBundledProfilesUseMeasuredStopsOnIPad() async throws {
        let profiles = try await engine().profiles()
        for (name, count) in [("APO-Digitar 43XL + iiic", 45), ("APO-Digitar 80N", 6)] {
            let summary = try XCTUnwrap(profiles.first { $0.name == name })
            let profile = try LCCProfileStore().load(summary.id)
            XCTAssertEqual(profile.captures.count, count)
            XCTAssertEqual(profile.captures.map(\.shiftX).min(), -18.08)
            XCTAssertEqual(profile.captures.map(\.shiftX).max(), 18.16)
            XCTAssertEqual(profile.captures.map(\.shiftY).min(), -18.35)
            XCTAssertEqual(profile.captures.map(\.shiftY).max(), 24.81)
            XCTAssertNotNil(summary.resolvedEndStops)
        }
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
        var settings = MobileExportSettings();settings.format = "dng";settings.longEdge = 6000
        let output = try await engine.export(photo: nil,edit: .neutral,plan: corrected,manifest: nil,settings: settings,
                                            cancellation: .init(),progress: { text,_ in print("RAW EXPORT",text) })
        XCTAssertTrue(try XCTUnwrap(PanoramaManifest.read(from: output)).correctionApplied)
        let validation = inputs.deletingLastPathComponent().appendingPathComponent("ValidationOutputs",isDirectory: true)
        try FileManager.default.createDirectory(at: validation,withIntermediateDirectories: true)
        let saved = validation.appendingPathComponent("Boston-6000.dng")
        try? FileManager.default.removeItem(at: saved)
        try FileManager.default.copyItem(at: output,to: saved)
        print("REAL ORIGINS",plan.origins,"gains",plan.gains,"MASK",plan.maskWidth,plan.maskHeight)
        let scene = try PanoramaEngine().renderComposite(corrected,outputLongEdge: 6000)
        let context = CIContext()
        try context.writePNGRepresentation(of: scene.applyingFilter("CIExposureAdjust",parameters: ["inputEV": -1]),to: validation.appendingPathComponent("Boston-before-DNG.png"),format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let uncorrected = try PanoramaEngine().renderComposite(plan,outputLongEdge: 6000)
        try context.writePNGRepresentation(of: uncorrected.applyingFilter("CIExposureAdjust",parameters: ["inputEV": -1]),to: validation.appendingPathComponent("Boston-no-LCC.png"),format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let exportedPreview = try await engine.frame(MobilePhoto(id: "export",name: "export",url: output,rating: 0,width: 0,height: 0),edit: .neutral,hdr: false,edge: 6000)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(validation.appendingPathComponent("Boston-6000-preview.png") as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,exportedPreview.image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
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

    func testLargeLinearDNGHasContinuousTileBoundaries() throws {
        let width = 6000, height = 773
        let gradient = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0,y: 0), "inputPoint1": CIVector(x: CGFloat(width),y: CGFloat(height)),
            "inputColor0": CIColor(red: 0.2,green: 0.3,blue: 0.4),
            "inputColor1": CIColor(red: 0.6,green: 0.7,blue: 0.8)
        ])?.outputImage).cropped(to: CGRect(x: 0,y: 0,width: width,height: height))
        // Model the partial coverage seen at RAW/resampling joins in the real Boston panorama.
        // These lines deliberately do not follow the 256-pixel DNG tile lattice.
        let gray = CIImage(color: CIColor(red: 0.8,green: 0.8,blue: 0.8))
        var coverage = CIImage(color: .white).cropped(to: gradient.extent)
        for x in stride(from: 619,to: width,by: 619) {
            coverage = gray.cropped(to: CGRect(x: x,y: 0,width: 4,height: height)).composited(over: coverage)
        }
        coverage = gray.cropped(to: CGRect(x: 0,y: 301,width: width,height: 3)).composited(over: coverage)
        let image = gradient.applyingFilter("CIBlendWithMask",parameters: ["inputBackgroundImage": CIImage(color: .clear),"inputMaskImage": coverage])
            .cropped(to: gradient.extent)
        let context = CIContext(options: [.workingColorSpace: PanoramaEngine.linearSpace])
        let url = folder.appendingPathComponent("continuous-6000.dng")
        try LinearDNGWriter.write(image: image,context: context,to: url)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        raw.boostAmount = 0; raw.isGamutMappingEnabled = false; raw.sharpnessAmount = 0
        raw.isLensCorrectionEnabled = false
        let decoded = try XCTUnwrap(raw.outputImage)
        XCTAssertEqual(decoded.extent.size,CGSize(width: width,height: height))
        var values = [Float](repeating: 0,count: width * height * 4)
        context.render(decoded,toBitmap: &values,rowBytes: width * 16,bounds: decoded.extent,
            format: .RGBAf,colorSpace: PanoramaEngine.linearSpace)
        var minimum: Float = 1, maximumBoundaryJump: Float = 0
        for y in 4..<(height-4) { for x in 4..<(width-4) {
            let p = (y*width+x)*4
            minimum = min(minimum,values[p],values[p+1],values[p+2])
            for c in 0..<3 {
                maximumBoundaryJump = max(maximumBoundaryJump,abs(values[p+c]-values[p-4+c]),abs(values[p+c]-values[p-width*4+c]))
            }
        }}
        XCTAssertGreaterThan(minimum,0.025,"No dark grid inside a smooth image")
        XCTAssertLessThan(maximumBoundaryJump,0.015,"Lossless DNG tiles must join continuously")
    }

    func testHDRPreviewPreservesHighlightsAndDeclaresHeadroom() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("hdr"))
        let photo = MobilePhoto(id: "hdr",name: "HDR",url: urls[0],rating: 0,width: 768,height: 512)
        var edit = EditModel.neutral; edit.light.exposure = 3
        let hdr = try await engine.frame(photo,edit: edit,hdr: true,edge: 320)
        let sdr = try await engine.frame(photo,edit: edit,hdr: false,edge: 320)
        func maximum(_ cg: CGImage) -> Float {
            let image = CIImage(cgImage: cg), context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])
            let maxImage = image.applyingFilter("CIAreaMaximum",parameters: ["inputExtent": CIVector(cgRect: image.extent)])
            var sample = [Float](repeating: 0,count: 4)
            context.render(maxImage,toBitmap: &sample,rowBytes: 16,bounds: CGRect(x: 0,y: 0,width: 1,height: 1),
                format: .RGBAf,colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
            return max(sample[0],sample[1],sample[2])
        }
        XCTAssertGreaterThan(maximum(hdr.image),1.2)
        XCTAssertLessThanOrEqual(maximum(sdr.image),1.001)
        XCTAssertNotEqual(hdr.histogram?.binsDigest(),sdr.histogram?.binsDigest())
        XCTAssertGreaterThan(hdr.image.contentHeadroom,1,"UIKit needs declared headroom for HDR presentation")
        await MainActor.run {
            print("SCREEN EDR",UIScreen.main.currentEDRHeadroom,UIScreen.main.potentialEDRHeadroom)
            let view = MobilePreviewSurface(); view.present(hdr.image,hdr: true)
            XCTAssertTrue((view.layer.contents as! CGImage) === hdr.image)
            if #available(iOS 26.0, *) { XCTAssertEqual(view.layer.preferredDynamicRange,.high) }
            else { XCTAssertTrue(view.layer.wantsExtendedDynamicRangeContent) }
            view.present(sdr.image,hdr: false)
            if #available(iOS 26.0, *) { XCTAssertEqual(view.layer.preferredDynamicRange,.standard) }
            else { XCTAssertFalse(view.layer.wantsExtendedDynamicRangeContent) }
        }
        var history = EditHistory(baseline: .neutral); history.commit(edit,label: "HDR",coalesce: false)
        _ = try await engine.importPhotos([photo.url],skipDuplicates: true,progress: { _,_ in })
        let importedPhotos = try await engine.photos()
        let imported = try XCTUnwrap(importedPhotos.first)
        try await engine.save(edit,history: history,id: imported.id)
        let thumb = try await engine.thumbnail(imported,hdr: true)
        let cached = try await self.engine().thumbnail(imported,hdr: true)
        XCTAssertEqual(cached.image.contentHeadroom,thumb.image.contentHeadroom)
        XCTAssertGreaterThan(maximum(cached.image),1.2,"Persisted thumbnails must keep HDR samples")
        XCTAssertEqual(cached.histogram,thumb.histogram)
        let cacheURLs = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Test.photonslibrary/MobilePreviews"),includingPropertiesForKeys: nil)
        XCTAssertTrue(cacheURLs.contains { $0.pathExtension == "pair" })
    }

    func testPanoramaToneUpdatesPreviewHistogramAndExport() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("tone"))
        let photos = urls.enumerated().map { MobilePhoto(id: "tone-\($0.offset)",name: $0.element.lastPathComponent,url: $0.element,rating: 0,width: 0,height: 0) }
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,cancellation: .init(),progress: { _,_ in })
        let baseline = try await engine.frame(plan,hdr: true)
        let tone = PanoramaToneSettings(exposureEV: 2,highlightHeadroom: 2)
        let adjusted = try await engine.adjustPanoramaTone(plan,settings: tone)
        let hdr = try await engine.frame(adjusted,hdr: true), sdr = try await engine.frame(adjusted,hdr: false)
        XCTAssertNotEqual(hdr.histogram?.binsDigest(),baseline.histogram?.binsDigest())
        XCTAssertNotEqual(hdr.histogram?.binsDigest(),sdr.histogram?.binsDigest())
        XCTAssertGreaterThan(hdr.image.contentHeadroom,1)
        XCTAssertLessThanOrEqual(hdr.image.contentHeadroom,2.01)
        XCTAssertEqual(adjusted.origins,plan.origins); XCTAssertEqual(adjusted.gains,plan.gains)
        var settings = MobileExportSettings(); settings.format = "dng"; settings.longEdge = 604
        let output = try await engine.export(photo: nil,edit: .neutral,plan: adjusted,manifest: nil,settings: settings,cancellation: .init(),progress: { _,_ in })
        XCTAssertEqual(try XCTUnwrap(PanoramaManifest.read(from: output)).tone,tone)
        let reset = try await engine.adjustPanoramaTone(adjusted,settings: .panoramaDefault)
        let resetFrame = try await engine.frame(reset,hdr: true)
        XCTAssertEqual(resetFrame.histogram?.binsDigest(),baseline.histogram?.binsDigest())
    }

    func testOptionalBostonSixFrameTone() async throws {
        let inputs = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0].appendingPathComponent("ValidationInputs/628-633")
        let urls = (628...633).map { inputs.appendingPathComponent(String(format: "B%07d.3FR",$0)) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw XCTSkip("Optional local six-frame Boston fixture") }
        let engine = engine(), photos = urls.enumerated().map { MobilePhoto(id: "six-\($0.offset)",name: $0.element.lastPathComponent,url: $0.element,rating: 0,width: 0,height: 0) }
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,tone: .init(),cancellation: .init(),progress: { text,_ in print("BOSTON SIX",text) })
        let before = try await engine.frame(plan,hdr: true)
        let tone = PanoramaToneSettings(exposureEV: 1,highlightHeadroom: 2)
        let adjusted = try await engine.adjustPanoramaTone(plan,settings: tone)
        let after = try await engine.frame(adjusted,hdr: true)
        XCTAssertEqual(plan.sources.count,6); XCTAssertEqual(adjusted.origins,plan.origins)
        XCTAssertNotEqual(before.histogram?.binsDigest(),after.histogram?.binsDigest())
        XCTAssertGreaterThan(after.image.contentHeadroom,1); XCTAssertLessThan(after.image.contentHeadroom,2.01)
        let outputs = inputs.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ValidationOutputs")
        try FileManager.default.createDirectory(at: outputs,withIntermediateDirectories: true)
        for (name,frame) in [("628-before",before),("628-brighter",after)] {
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(outputs.appendingPathComponent("\(name).png") as CFURL,"public.png" as CFString,1,nil))
            CGImageDestinationAddImage(destination,frame.image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        print("BOSTON SIX TONE",plan.size,before.image.contentHeadroom,after.image.contentHeadroom)
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
