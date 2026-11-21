import CoreImage
import Foundation
import PhotonsCore
import PhotonsPanorama

/// Measure how well the chosen encoder compresses this photograph. At most four
/// 256 × 256 patches enter the encoder, regardless of the panorama dimensions.
public enum ExportSizeSample {
    public static func measure(preview: CGImage, content: ImageSize, preset: ExportPreset,
                               linearDNG: Bool) throws -> ExportFileSizeEstimate? {
        guard let output = ExportFileSizeEstimator.outputSize(content: content, preset: preset, linearDNG: linearDNG),
              let space = LinearPixels.extendedLinearColorSpace(for: preset.colorSpace) else { return nil }
        try Task.checkCancellation()
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let image = CIImage(cgImage: preview)
        // Do not invent high-frequency detail by upsampling a screen preview.
        let scale = min(1, Double(max(output.width, output.height)) / Double(max(preview.width, preview.height)))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = min(512, max(1, Int(scaled.extent.width)))
        let h = min(512, max(1, Int(scaled.extent.height)))
        let xSplit = w / 2, ySplit = h / 2
        var mosaic = CIImage.empty()
        for (y, height, fy) in [(0, ySplit, 0.25), (ySplit, h - ySplit, 0.75)] where height > 0 {
            for (x, width, fx) in [(0, xSplit, 0.25), (xSplit, w - xSplit, 0.75)] where width > 0 {
                let left = floor((scaled.extent.width - Double(w)) * fx) + Double(x)
                let bottom = floor((scaled.extent.height - Double(h)) * fy) + Double(y)
                let patch = scaled.cropped(to: CGRect(x: left, y: bottom, width: Double(width), height: Double(height)))
                    .transformed(by: CGAffineTransform(translationX: Double(x) - left, y: Double(y) - bottom))
                mosaic = patch.composited(over: mosaic)
            }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(linearDNG ? "dng" : preset.format.fileExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if linearDNG {
            try LinearDNGWriter.write(image: mosaic, context: context, to: temporary, primaries: preset.colorSpace,
                                      cancellation: .init(isCancelled: { Task.isCancelled }))
        } else {
            var rgba = [Float16](repeating: 0, count: w * h * 4)
            context.render(mosaic, toBitmap: &rgba, rowBytes: w * 8, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBAh, colorSpace: space)
            let linear = LinearPixels(width: w, height: h, rgba: rgba, primaries: preset.colorSpace)
            var image = linear.displaySDR(bitDepth: preset.effectiveBitDepth, toneMap: preset.isHDR ? .global : nil)
            if preset.hdrKind == .gainMap, preset.hdr?.halfSize == true {
                let crop = GainMapSizing.plan(image.size, halfSize: true).crop
                if crop.isNeeded { image = GainMapSizing.crop(image, crop) }
            }
            try Exporter.write(image, to: temporary, options: preset.exportOptions)
        }
        try Task.checkCancellation()
        guard let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        let sample = ImageSize(width: w, height: h)
        let sampleHeader = min(Double(bytes) - 1, fixedBytes(sample, linearDNG: linearDNG, preset: preset))
        let outputHeader = linearDNG ? fixedBytes(output, linearDNG: true, preset: preset) : sampleHeader
        let ratio = Double(output.width) * Double(output.height) / Double(w * h)
        let projected = max(1, Double(bytes) - sampleHeader) * ratio + outputHeader
        guard projected.isFinite, projected < Double(Int64.max) else { return nil }
        let estimated = Int64(projected.rounded())
        return ExportFileSizeEstimate(lowerBytes: estimated, upperBytes: estimated, fileCount: 1)
    }

    private static func fixedBytes(_ size: ImageSize, linearDNG: Bool, preset: ExportPreset) -> Double {
        if linearDNG {
            let scale = min(1, 512 / Double(max(size.width, size.height)))
            let previewBytes = Double(max(1, Int(Double(size.width) * scale)) * max(1, Int(Double(size.height) * scale)) * 3)
            let tiles = ceil(Double(size.width) / 256) * ceil(Double(size.height) / 256)
            return 1_024 + previewBytes + tiles * 8
        }
        // Keep codec headers and profiles out of the per-pixel extrapolation.
        return preset.hdrKind == .gainMap ? 4_096 : 1_024
    }
}

/// A sheet can update while a thumbnail or encoder is running. The complete request
/// is the task identity so a completed estimate is only used with its original settings.
public struct ExportSizeRequest: Equatable, Sendable {
    public let contents: [ImageSize]
    public let preset: ExportPreset
    public let linearDNG: Bool
    public let preview: CGImage?
    public let sources: [URL?]

    public init(contents: [ImageSize], preset: ExportPreset, linearDNG: Bool, preview: CGImage? = nil, sources: [URL?] = []) {
        self.contents = contents
        self.preset = preset
        self.linearDNG = linearDNG
        self.preview = preview
        self.sources = sources
    }

    public func measure(load: @escaping @Sendable (URL) -> CGImage? = { _ in nil }) async -> ExportFileSizeEstimate? {
        guard !contents.isEmpty, preview != nil || !sources.isEmpty else { return nil }
        // Uncompressed TIFF payload size follows directly from geometry and channel count.
        if !linearDNG && preset.format == .tiff && preset.tiffCompression == .uncompressed { return nil }
        let worker = Task.detached(priority: .utility) { () -> ExportFileSizeEstimate? in
            let indices = Set([0, self.contents.count / 2, self.contents.count - 1]).sorted()
            var factors: [Int: Double] = [:]
            var samples: [Int: ExportFileSizeEstimate] = [:]
            let defaults = self.contents.map { ExportFileSizeEstimator.estimate(contents: [$0], preset: self.preset, linearDNG: self.linearDNG) }
            for i in indices {
                guard !Task.isCancelled else { return nil }
                let result: ExportFileSizeEstimate? = autoreleasepool {
                    let preview = self.preview ?? (self.sources.indices.contains(i) ? self.sources[i].flatMap(load) : nil)
                    guard let preview else { return nil }
                    return try? ExportSizeSample.measure(preview: preview, content: self.contents[i], preset: self.preset, linearDNG: self.linearDNG)
                }
                if let result, let base = defaults[i] {
                    samples[i] = result
                    factors[i] = Double(result.upperBytes) / (Double(base.lowerBytes) * 0.5 + Double(base.upperBytes) * 0.5)
                }
            }
            guard !Task.isCancelled, !samples.isEmpty else { return nil }
            var estimates: [ExportFileSizeEstimate] = []
            for (i, base) in defaults.enumerated() {
                if let sample = samples[i] { estimates.append(sample); continue }
                guard let base, let closest = indices.filter({ factors[$0] != nil }).min(by: { abs(i - $0) < abs(i - $1) }),
                      let factor = factors[closest] else { return nil }
                let projected = (Double(base.lowerBytes) * 0.5 + Double(base.upperBytes) * 0.5) * factor
                guard projected.isFinite, projected < Double(Int64.max) else { return nil }
                let bytes = max(1, Int64(projected.rounded()))
                estimates.append(.init(lowerBytes: bytes, upperBytes: bytes, fileCount: 1))
            }
            return .total(estimates)
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
}
