import CoreImage
import PhotonsCore
import PhotonsPanorama
import XCTest
@testable import PhotonsExport

final class SampledExportSizeTests: XCTestCase {
    func testEstimatesAgainstWrittenFiles() throws {
        let space = try XCTUnwrap(LinearPixels.extendedLinearColorSpace(for: .rec2020))
        let context = CIContext(options: [.workingColorSpace: space])
        let scene: CIImage
        if let path = ProcessInfo.processInfo.environment["PHOTONS_SIZE_TEST_IMAGE"] {
            let source = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: path)))
            let scale = min(1, 1536 / max(source.extent.width, source.extent.height))
            scene = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            let w = 1024, h = 768
            var pixels = [Float16](repeating: 1, count: w * h * 4)
            var rng: UInt32 = 7
            for y in 0..<h {
                for x in 0..<w {
                    rng = rng &* 1664525 &+ 1013904223
                    let noise = Double(rng >> 16) / 65535 * 0.015
                    let light = 0.3 + 0.18 * sin(Double(x + y) / 18) + noise
                    for c in 0..<3 { pixels[(y*w+x)*4+c] = Float16(light + 0.12 * Double(c)) }
                }
            }
            scene = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: w * 8,
                            size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: space)
        }
        let w = Int(scene.extent.width), h = Int(scene.extent.height)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let preview = try XCTUnwrap(context.createCGImage(scene, from: bounds, format: .RGBAh, colorSpace: space))
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        context.render(scene, toBitmap: &rgba, rowBytes: w * 8, bounds: bounds, format: .RGBAh, colorSpace: space)
        let linear = LinearPixels(width: w, height: h, rgba: rgba, primaries: .rec2020)
        let size = ImageSize(width: w, height: h)
        let dngPreset = ExportPreset(format: .tiff, bitDepth: 16)
        let cases: [(String, ExportPreset)] = [
            ("dng", dngPreset), ("zip", dngPreset),
            ("lzw", ExportPreset(format: .tiff, tiffCompression: .lzw, bitDepth: 16)),
            ("raw-tiff", ExportPreset(format: .tiff, tiffCompression: .uncompressed, bitDepth: 16)),
            ("pq-tiff", ExportPreset(format: .tiff, bitDepth: 16, hdrKind: .pq)),
            ("jpeg", ExportPreset(format: .jpeg, colorSpace: .rec2020)),
            ("heic-hdr", ExportPreset(format: .heic, colorSpace: .rec2020, hdrKind: .gainMap)),
            ("png", ExportPreset(format: .png, bitDepth: 16, colorSpace: .rec2020))
        ]
        var sampledError = 0.0, originalError = 0.0
        for (label, preset) in cases {
            try autoreleasepool {
                let dng = label == "dng"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(dng ? "dng" : preset.format.fileExtension)
                defer { try? FileManager.default.removeItem(at: url) }
                if dng {
                    try LinearDNGWriter.write(image: scene.cropped(to: bounds), context: context, to: url)
                } else {
                    var display = linear.displaySDR(bitDepth: preset.effectiveBitDepth, toneMap: preset.isHDR ? .global : nil)
                    if preset.hdrKind == .gainMap, preset.hdr?.halfSize == true {
                        let crop = GainMapSizing.plan(display.size, halfSize: true).crop
                        if crop.isNeeded { display = GainMapSizing.crop(display, crop) }
                    }
                    try Exporter.write(display, to: url, options: preset.exportOptions)
                }
                let actual = Double(try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
                let measured = try XCTUnwrap(ExportSizeSample.measure(preview: preview, content: size, preset: preset, linearDNG: dng))
                let original = try XCTUnwrap(ExportFileSizeEstimator.file(output: size, preset: preset, linearDNG: dng))
                let error = abs(Double(measured.upperBytes) / actual - 1)
                let baseline = abs((Double(original.upperBytes) + Double(original.lowerBytes)) / (2 * actual) - 1)
                print("Size sample \(label): actual=\(Int(actual)) estimate=\(measured.upperBytes) error=\(Int(error * 100))% baseline=\(Int(baseline * 100))%")
                sampledError += error
                originalError += baseline
                XCTAssertLessThan(error, 0.45, label)
            }
        }
        XCTAssertLessThan(sampledError, originalError)
    }
}
