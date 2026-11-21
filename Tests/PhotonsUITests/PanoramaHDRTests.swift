import XCTest
import AppKit
import SwiftUI
import CoreImage
import ImageIO
import Metal
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

final class PanoramaHDRTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private func scene() -> CIImage {
        // CI coordinates: red at the top, blue at the bottom; neither is a neutral
        // sample, so this also catches accidentally retagging sRGB as Display P3.
        let red = CIImage(color: CIColor(red: 2, green: 0, blue: 0, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 32, width: 96, height: 32))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 0.5, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        return red.composited(over: blue)
    }

    func testExportBridgeKeepsHDRPrimariesOrientationAndSizing() throws {
        let preset = ExportPreset(format: .tiff, longEdge: 48, bitDepth: 16, colorSpace: .displayP3,
                                  hdrKind: .pq, sizingMode: .longEdge)
        let result = try PanoramaExportRenderer.render(scene: scene(), preset: preset)
        XCTAssertEqual(result.width, 48); XCTAssertEqual(result.height, 32)
        XCTAssertEqual(result.bitDepth, 16); XCTAssertEqual(result.primaries, .displayP3)
        let linear = try XCTUnwrap(result.linear)
        // sRGB red transformed to P3, rather than the unconverted (2, 0, 0).
        XCTAssertEqual(Float(linear.rgba[0]), 1.645, accuracy: 0.015)
        XCTAssertEqual(Float(linear.rgba[1]), 0.0664, accuracy: 0.01)
        XCTAssertLessThan(Float(linear.rgba[2]), 0.05)
        let bottom = (linear.width * (linear.height - 1)) * 4
        XCTAssertGreaterThan(Float(linear.rgba[bottom + 2]), 0.4)
        XCTAssertLessThan(Float(linear.rgba[bottom]), 0.01)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.write(result, to: url, options: preset.exportOptions)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(cg.bitsPerComponent, 16)
        XCTAssertEqual(cg.colorSpace?.name, CGColorSpace.displayP3_PQ)
        let roundTrip = try PanoramaExportRenderer.render(scene: CIImage(cgImage: cg), preset: ExportPreset(
            format: .tiff, bitDepth: 16, colorSpace: .displayP3, hdrKind: .pq))
        XCTAssertEqual(Float(try XCTUnwrap(roundTrip.linear).rgba[0]), 1.645, accuracy: 0.04)
    }

    @MainActor
    func testEDRSurfaceKeepsHighlightsAndFitsWholePanorama() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let context = CIContext()
        let cg = try XCTUnwrap(context.createCGImage(scene(), from: scene().extent, format: .RGBAh, colorSpace: space))
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = PanoramaHDRPreviewView(); window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        view.setImage(cg); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.surface.frame.width, 300, accuracy: 0.1)
        XCTAssertEqual(view.surface.frame.height, 200, accuracy: 0.1)
        XCTAssertEqual(view.surface.frame.minY, 50, accuracy: 0.1)
        let layer = try XCTUnwrap(view.surface.layer as? CAMetalLayer)
        XCTAssertEqual(layer.pixelFormat, CanvasPresenter.Storage.linear16.pixelFormat)
        XCTAssertEqual(layer.colorspace, CanvasPresenter.Storage.linear16.colorSpace)
        let texture = try XCTUnwrap(view.surface.renderForTesting(width: 96, height: 64))
        var pixels = [UInt16](repeating: 0, count: 96 * 64 * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 96 * 8, from: MTLRegionMake2D(0, 0, 96, 64), mipmapLevel: 0)
        }
        XCTAssertEqual(Float(Float16(bitPattern: pixels[0])), 1.645, accuracy: 0.02)
        XCTAssertGreaterThan(Float(Float16(bitPattern: pixels[(63 * 96) * 4 + 2])), 0.4)
    }

    func testPanoramaPinchAnchorsFinalOutputPixelsAndBoundsPanning() throws {
        let pixels = CGSize(width: 24_000, height: 16_000)
        let view = CGSize(width: 900, height: 600)
        let anchor = CGPoint(x: 200, y: 150)
        var zoom = PanoramaPreviewZoom()
        XCTAssertEqual(zoom.fit(pixels, in: view, backing: 2), 0.075, accuracy: 1e-12)
        zoom.magnify(to: 0.078, at: anchor, pixels: pixels, in: view, backing: 2)
        let frame = zoom.imageFrame(pixels, in: view, backing: 2)
        XCTAssertEqual((anchor.x - frame.minX) / frame.width, anchor.x / view.width, accuracy: 1e-12)
        XCTAssertEqual((anchor.y - frame.minY) / frame.height, anchor.y / view.height, accuracy: 1e-12)
        zoom.magnify(to: 1.375, at: anchor, pixels: pixels, in: view, backing: 2)
        XCTAssertEqual(zoom.imageFrame(pixels, in: view, backing: 2).width, 16_500)
        zoom.pan(by: CGPoint(x: -100_000, y: 100_000), pixels: pixels, in: view, backing: 2)
        let edge = zoom.imageFrame(pixels, in: view, backing: 2)
        XCTAssertEqual(edge.maxX, view.width, accuracy: 1e-8)
        XCTAssertEqual(edge.minY, 0, accuracy: 1e-8)
    }

    @MainActor
    func testZoomedPanoramaSamplesTheCachedHDRPreviewAndDoubleClickRestoresFit() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let cg = try XCTUnwrap(CIContext().createCGImage(scene(), from: scene().extent, format: .RGBAh, colorSpace: space))
        let view = PanoramaHDRPreviewView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        view.outputPixels = CGSize(width: 24_000, height: 16_000)
        view.setImage(cg)
        let anchor = CGPoint(x: 150, y: 40)
        view.applyScale(1.375, at: anchor)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.zoom.scale, 1.375)
        XCTAssertEqual(view.surface.frame, view.bounds)
        let rect = try XCTUnwrap(view.surface.sourceWindow)
        XCTAssertLessThan(rect.maxY, 0.5)
        let texture = try XCTUnwrap(view.surface.renderForTesting(width: 2, height: 2))
        var rgba = [Float16](repeating: 0, count: 16)
        rgba.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        }
        XCTAssertEqual(Float(rgba[0]), 1.645, accuracy: 0.02)
        XCTAssertEqual(Float(rgba[8]), 1.645, accuracy: 0.02)
        view.toggleZoom(at: anchor)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.zoom.scale)
        XCTAssertNil(view.surface.sourceWindow)
        view.toggleZoom(at: anchor)
        XCTAssertEqual(view.zoom.scale, DoubleClickZoom.target)
    }

    @MainActor
    func testHostedHistogramFitsItsLastReadoutRow() throws {
        let image = try XCTUnwrap(CIContext().createCGImage(scene(), from: scene().extent))
        let window = TestWindows.make(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        let host = NSHostingView(rootView: PanoramaHDRPreview(image: image))
        window.contentView = host
        TestWindows.show(window)
        host.layoutSubtreeIfNeeded()

        func histogram(in parent: NSView) -> HistogramCardView? {
            if let card = parent as? HistogramCardView { return card }
            return parent.subviews.lazy.compactMap { histogram(in: $0) }.first
        }
        let card = try XCTUnwrap(histogram(in: host))
        let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
        card.cacheDisplay(in: card.bounds, to: bitmap)
        XCTAssertGreaterThan(card.readoutRowRect.height, 0)
        XCTAssertEqual(card.bounds.maxY, card.readoutRowRect.maxY, accuracy: 0.5)
        let frame = card.convert(card.bounds, to: window.contentView)
        let topInset = host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
        // 12 pt to the overlay plus 6 pt inside its material background.
        XCTAssertEqual(topInset, 18, accuracy: 0.5)
    }

    @MainActor
    func testHostedPanoramaReceivesWindowDoubleClicks() throws {
        let cg = try XCTUnwrap(CIContext().createCGImage(scene(), from: scene().extent))
        let window = TestWindows.make(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PanoramaHDRPreview(image: cg, outputPixels: CGSize(width: 12000, height: 8000)))
        window.contentView = host
        TestWindows.show(window)
        host.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        func canvas(in parent: NSView) -> PanoramaHDRPreviewView? {
            if let canvas = parent as? PanoramaHDRPreviewView { return canvas }
            return parent.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        let view = try XCTUnwrap(canvas(in: host))
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for count in 1...4 {
            window.sendEvent(CropUITestSupport.mouse(.leftMouseDown, at: point, in: window, clickCount: count))
            window.sendEvent(CropUITestSupport.mouse(.leftMouseUp, at: point, in: window, clickCount: count))
            CropUITestSupport.pump(0.02)
            XCTAssertEqual(view.zoom.scale, (2...3).contains(count) ? CGFloat(DoubleClickZoom.target) : nil)
        }
    }

    func testResizingHDRKeepsUnclippedLinearCompanion() throws {
        let pixel: [Float16] = [8, 2, 0.5, 1]
        let pixels = Array(repeating: pixel, count: 32).flatMap { $0 }
        let source = LinearPixels(width: 8, height: 4, rgba: pixels, primaries: .displayP3)
        let resized = DisplayResample.fitLongEdge(source.displaySDR(bitDepth: 16), to: 4)
        let linear = try XCTUnwrap(resized.linear)
        XCTAssertEqual(linear.width, 4); XCTAssertEqual(linear.height, 2)
        XCTAssertEqual(Float(linear.rgba[0]), 8, accuracy: 0.01)
        XCTAssertEqual(Float(linear.rgba[1]), 2, accuracy: 0.01)
        XCTAssertEqual(linear.primaries, .displayP3)
    }

    @MainActor
    func testSharedSheetUsesPanoramaRendererAndNativeDefaultGainMap() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("ISO gain map needs macOS 15") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = ExportSheetModel(preset: ExportSheetModel.defaultPreset, outputDirectory: dir,
            presetStore: ExportPresetStore(directory: dir), draftStore: ExportSheetModelTests.MemoryDraftStore())
        model.preset.sizingMode = .percent; model.preset.percent = 50
        model.run(items: [ExportItem(id: "test", name: "panorama")]) { _, preset, _ in
            try PanoramaExportRenderer.render(scene: self.scene(), preset: preset)
        }
        for _ in 0..<300 where model.phase == .running { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(model.phase, .finished)
        let outcome = try XCTUnwrap(model.report?.written.first, model.report?.failures.first?.error ?? "missing output")
        let url = try XCTUnwrap(outcome.fileURL)
        XCTAssertEqual(url.pathExtension, "heic")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 48, "percentage must be applied only once")
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 32)
        let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
        XCTAssertNotNil(gainMap, "default native export must carry an HDR gain map")
        XCTAssertEqual(model.preset.colorSpace, .displayP3)
    }
}
