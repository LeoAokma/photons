import XCTest
import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 161 §5 — the whole draft (format, size, HDR, quality, directory…) is remembered in one versioned
/// JSON blob, written only after a successful export and on close. M1–M4 are the acceptance list.
@MainActor
final class ExportSheetDraftPersistenceTests: XCTestCase {

    final class MemoryStore: ExportDraftPersistence.Store {
        var values: [String: Data] = [:]
        var writes = 0
        /// 421b —— 按 key 计写次数。关闭现在会写两条偏好：主 draft（`storageKey`）与当前输出页
        /// （`photons.exportTab.*.v1`）。两者是**不同的**偏好，所以「一次写」这条契约按 key 计。
        private(set) var writesByKey: [String: Int] = [:]
        func exportDraftData(forKey key: String) -> Data? { values[key] }
        func setExportDraftData(_ data: Data?, forKey key: String) {
            if let data {
                values[key] = data
                writes += 1
                writesByKey[key, default: 0] += 1
            } else {
                values.removeValue(forKey: key)
            }
        }
        func writes(forKey key: String) -> Int { writesByKey[key] ?? 0 }
    }

    private var scratch: URL!
    private var store: MemoryStore!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-draft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = MemoryStore()
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func model() -> ExportSheetModel {
        ExportSheetModel(presetStore: ExportPresetStore(directory: scratch),
                         draftStore: store)
    }

    private func report(written: Int) -> BatchExportReport {
        let outcomes = (0..<written).map { index in
            BatchExportOutcome(index: index, id: "i\(index)", sourceName: "i\(index)",
                               fileURL: scratch.appendingPathComponent("i\(index).png"),
                               fileBytes: 1024,
                               pixelSize: ImageSize(width: 10, height: 10), seconds: 0.1,
                               xmpURL: nil, warnings: [], error: nil)
        }
        return BatchExportReport(outcomes: outcomes, seconds: 0.1,
                                 requestedConcurrency: 1, peakConcurrency: 1)
    }

    // MARK: M1

    func testM1_RememberedDraftSurvivesARestart_FormatSizeAndDirectory() {
        let first = model()
        first.preset.format = .jpeg
        first.preset.quality = 0.66
        first.preset.colorSpace = .sRGB
        first.preset.bitDepth = 8
        first.preset.hdr = nil
        first.selectSizingMode(.longEdge)
        first.preset.longEdge = 1200
        first.preset.nameTemplate = "{date}-{name}"
        let directory = scratch.appendingPathComponent("remembered", isDirectory: true)
        first.outputDirectory = directory

        XCTAssertEqual(store.writes, 0, "editing must not write defaults on every tick")
        first.saveDraftOnClose()
        // 421b —— 关闭写两条**不同**的偏好：主 draft 一次，当前输出页（`photons.exportTab.sdr.v1`）
        // 一次。各自都只写一次 —— 「关闭不写 N 次」的契约按 key 成立。
        XCTAssertEqual(store.writes(forKey: ExportDraftPersistence.storageKey), 1,
                       "主 draft 关闭时写一次")
        // 当前输出页那条写到 `photons.exportTab.<hdr|sdr>.v1`：档位由 `hdrEnabled || usesLinearDNG`
        // 决定，所以断言写成「两个键加起来恰好一次」，而不是猜当前是哪一档。
        XCTAssertEqual(store.writes(forKey: "photons.exportTab.hdr.v1")
                       + store.writes(forKey: "photons.exportTab.sdr.v1"), 1,
                       "当前输出页关闭时写一次（HDR 或 SDR，视当前档位）")

        let second = model()
        XCTAssertEqual(second.preset.format, .jpeg)
        XCTAssertEqual(second.preset.quality, 0.66)
        XCTAssertEqual(second.preset.colorSpace, .sRGB)
        XCTAssertEqual(second.preset.sizingMode, .longEdge)
        XCTAssertEqual(second.preset.longEdge, 1200)
        XCTAssertEqual(second.preset.nameTemplate, "{date}-{name}")
        XCTAssertEqual(second.outputDirectory.standardizedFileURL, directory.standardizedFileURL)
    }

    // MARK: M2

    func testM2_BadJSONFallsBackToTheDefaultsAndClearsTheBlob() {
        store.values[ExportDraftPersistence.storageKey] = Data("{not json".utf8)

        let sheet = model()

        XCTAssertEqual(sheet.preset, ExportSheetModel.defaultPreset)
        XCTAssertEqual(sheet.preset.sizingMode, .none)
        XCTAssertNotNil(sheet.draftNotice, "坏数据被清掉时必须留下记录，不能静默")
        XCTAssertNil(store.values[ExportDraftPersistence.storageKey], "坏 JSON 必须清除")
    }

    // MARK: M3

    func testM3_CloseSavesTheExportedDraftNotUnexportedEditsAfterwards() {
        let first = model()
        first.preset.format = .jpeg
        first.selectSizingMode(.longEdge)
        first.preset.longEdge = 1600
        let exportedDirectory = scratch.appendingPathComponent("exported", isDirectory: true)
        first.outputDirectory = exportedDirectory

        // The report makes writtenCount > 0, which is the one successful-export write point.
        first.finish(with: report(written: 1))
        XCTAssertEqual(first.phase, .finished)
        XCTAssertEqual(store.writes, 1, "导出成功后写一次")

        // Post-report edits are not exported. Closing must not persist them.
        first.preset.format = .png
        first.selectSizingMode(.none)
        first.outputDirectory = scratch.appendingPathComponent("never-exported", isDirectory: true)
        XCTAssertEqual(first.phase, .idle, "改字段后状态行回到参数")

        first.saveDraftOnClose()

        let second = model()
        XCTAssertEqual(second.preset.format, .jpeg, "拿到的是导出那一次的设置")
        XCTAssertEqual(second.preset.sizingMode, .longEdge)
        XCTAssertEqual(second.preset.longEdge, 1600)
        XCTAssertEqual(second.outputDirectory.standardizedFileURL,
                       exportedDirectory.standardizedFileURL)
    }

    // MARK: M4

    func testM4_FirstEverOpenIsOriginalSizeWithTheFactoryDraft() {
        let sheet = model()
        XCTAssertEqual(sheet.preset, ExportSheetModel.defaultPreset)
        XCTAssertEqual(sheet.preset.sizingMode, .none)
        XCTAssertNil(sheet.preset.longEdge)
        XCTAssertEqual(sheet.preset.quality, 0.85)
        XCTAssertEqual(sheet.preset.format, .heic)
        XCTAssertEqual(sheet.outputDirectory, ExportSheetModel.defaultOutputDirectory)
        XCTAssertNil(sheet.draftNotice)
    }

    /// Extra: the blob is versioned JSON and a second save of identical settings is a no-op.
    func testTheBlobIsVersionedJSONAndIdenticalSavesAreDeduplicated() throws {
        let sheet = model()
        sheet.saveDraftOnClose()
        let data = try XCTUnwrap(store.values[ExportDraftPersistence.storageKey])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, ExportDraftPersistence.currentVersion)
        XCTAssertNotNil(object["preset"])
        XCTAssertNotNil(object["outputDirectory"])

        let writes = store.writes
        sheet.saveDraftOnClose()
        XCTAssertEqual(store.writes, writes, "没改动的关闭不该再写一次")
    }
}
