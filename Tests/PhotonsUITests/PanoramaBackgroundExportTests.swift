import AppKit
import CoreImage
import XCTest
import PhotonsExport
import PhotonsPanorama
@testable import PhotonsUI

@MainActor
final class PanoramaBackgroundExportTests: XCTestCase {
    func testExportUsesOnlyTheSelectedDestination() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.tiff")
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        try CIContext().writeTIFFRepresentation(of: image, to: source, format: .RGBA16,
                                                colorSpace: PanoramaEngine.linearSpace)
        let plan = try PanoramaEngine().singlePhoto(PanoramaSource(url: source))
        let worker = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/photons-panorama-worker")
        let queue = BackgroundTasks(worker: worker)
        let missing = folder.appendingPathComponent("unused remembered folder", isDirectory: true)
        let chosen = folder.appendingPathComponent("chosen folder", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        for destination in [ExportDestination.sourceFolder, .chosenFolder] {
            var preset = ExportPreset(format: .tiff)
            preset.destination = destination
            preset.subfolder = "renders"
            let useSource = destination == .sourceFolder
            try queue.submit(plan: plan, manifest: PanoramaManifest(plan: plan), preset: preset,
                             dng: true, directory: useSource ? missing : chosen) { _, done in done(nil) }
            let task = try XCTUnwrap(queue.tasks.last)
            for _ in 0..<400 where task.active { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertEqual(task.state, .finished, task.message)
            let output = try XCTUnwrap(task.output)
            let expected = (useSource ? folder : chosen).appendingPathComponent("renders/photo_pano.dng")
            XCTAssertEqual(output.standardizedFileURL.path, expected.standardizedFileURL.path)
            XCTAssertNotNil(try PanoramaManifest.read(from: output))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
