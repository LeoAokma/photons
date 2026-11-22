import XCTest
import PhotonsCore
@testable import PhotonsUI

@MainActor
final class AutoColorCardTests: XCTestCase {
    func testApplyingAutomaticColorAddsOneUndoableEditToTheSelectedPhoto() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, asset) = try CropUITestSupport.makeSession(in: folder, width: 512, height: 512)
        let url = try XCTUnwrap(session.fileURL(for: asset))
        let chart = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/wb-calibrate/chart256.dng")
        try Data(contentsOf: chart).write(to: url)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        session.applyEdit { $0.light.exposure = -0.25; $0.color.saturation = -85 }
        XCTAssertTrue(session.commitEdit(label: "Starting values"))
        let before = session.edit, historyCount = session.history.count
        _ = try loupe.makeFrame(asset: asset, url: url, viewport: ImageSize(width: 512, height: 512),
                                decodeScale: 1)
        loupe.autoColor()
        let deadline = Date().addingTimeInterval(10)
        while session.history.count == historyCount && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(session.history.count, historyCount + 1)
        XCTAssertNotEqual(session.edit.color, before.color)
        XCTAssertEqual(session.edit.light, before.light)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit, before)
    }
}
