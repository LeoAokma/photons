import AppKit
import SwiftUI
import CoreImage
import PhotonsCore
import PhotonsExport
import PhotonsPanorama

enum PanoramaExportKind: Hashable { case standard, losslessDNG }

/// Adapt the frozen, scene-linear composite to the application's existing export contract.
/// The SDR base and the HDR companion always come from the same pixels.
enum PanoramaExportRenderer {
    static func render(plan: PanoramaPlan, preset: ExportPreset, cancel: CancellationToken) throws -> DisplayImage {
        let engine = PanoramaEngine()
        let cancellation = PanoramaCancellation(isCancelled: { cancel.isCancelled })
        let scene = try engine.renderComposite(plan, cancellation: cancellation)
        try cancellation.check()
        return try render(scene: scene, preset: preset)
    }

    static func render(scene: CIImage, preset: ExportPreset) throws -> DisplayImage {
        let content = ImageSize(width: Int(scene.extent.width), height: Int(scene.extent.height))
        // BatchExporter applies percentages to the returned pixels. Only pre-size an
        // absolute long edge here, otherwise 50% would be applied twice (25% output).
        let scale = preset.sizingMode == .longEdge ? preset.renderScale(content: content) : 1
        let size = ExportSizing.outputSize(content: content, scale: scale)
        let space = HDREncoding.linearColorSpace(for: preset.colorSpace)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh,
                                          .cacheIntermediates: false])
        defer { context.clearCaches() }
        let image = scene.transformed(by: CGAffineTransform(translationX: -scene.extent.minX, y: -scene.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(size.width) / scene.extent.width,
                                               y: CGFloat(size.height) / scene.extent.height))
        // CI bitmap rows already start at the top (unlike its Metal texture readback).
        var pixels = [Float16](repeating: 0, count: size.width * size.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: size.width * 8,
                bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height), format: .RGBAh, colorSpace: space)
        }
        let linear = LinearPixels(width: size.width, height: size.height, rgba: pixels, primaries: preset.colorSpace)
        return linear.displaySDR(bitDepth: preset.effectiveBitDepth,
                                 toneMap: preset.isHDR || preset.appliesSDRToneMap ? .global : nil)
    }
}

/// Only the pixel provider differs from a catalog export; all controls, remembered presets,
/// format/depth validation, gain maps, naming and reporting belong to ExportSheetModel.
@MainActor
final class PanoramaExportController {
    let model = ExportSheetModel()
    private var window: NSWindow?
    private let plan: PanoramaPlan

    init(plan: PanoramaPlan) {
        self.plan = plan
        let size = ImageSize(width: Int(plan.outputSize.width), height: Int(plan.outputSize.height))
        model.selectionCount = 1
        model.selectionNatives = [size]; model.selectionContents = [size]
        model.onClose = { [weak self] in self?.dismiss() }
        model.onChooseDirectory = { [weak self] in self?.chooseDirectory() }
        model.onReveal = { NSWorkspace.shared.activateFileViewerSelecting($0) }
        model.onExportRequest = { [weak self] in self?.run() }
    }

    func present(in parent: NSWindow) {
        let hosting = NSHostingController(rootView: ExportSheetView(model: model))
        hosting.sizingOptions = []
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ExportRowGrid.panelWidth,
            height: ExportRowGrid.contentMaxHeight), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "导出拼接图"
        sheet.contentViewController = hosting
        sheet.setContentSize(NSSize(width: ExportRowGrid.panelWidth, height: ExportRowGrid.contentMaxHeight))
        sheet.isReleasedWhenClosed = false
        window = sheet
        parent.beginSheet(sheet)
    }

    func dismiss() {
        model.cancel()
        model.saveDraftOnClose()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        window?.orderOut(nil); window = nil
    }

    private func chooseDirectory() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.directoryURL = model.outputDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.model.outputDirectory = url }
        }
    }

    private func run() {
        // No sourceURL: the composite has its own dimensions/orientation, so copying a single
        // RAW's crop/orientation metadata would misdescribe the exported panorama.
        let name = (plan.sources.first?.url.deletingPathExtension().lastPathComponent ?? "全景") + "_Panorama"
        let item = ExportItem(id: "panorama", name: name, cameraKey: plan.sources.first?.camera)
        let frozen = plan
        model.run(items: [item]) { _, preset, token in
            try PanoramaExportRenderer.render(plan: frozen, preset: preset, cancel: token)
        }
    }
}
