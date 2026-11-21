import Foundation
import ImageIO
import PhotonsLocalization

/// Image compression for flattened RGB TIFFs. ZIP uses Adobe Deflate (TIFF tag 259 = 8).
public enum TIFFCompression: String, Codable, CaseIterable, Sendable {
    case zip, lzw, uncompressed = "none", jpeg

    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .lzw: return "LZW"
        case .uncompressed: return L10n.tr("tiff.uncompressed")
        case .jpeg: return L10n.tr("tiff.jpeg")
        }
    }

    private var tag: Int {
        switch self {
        case .uncompressed: return 1
        case .lzw: return 5
        case .jpeg: return 7
        case .zip: return 8
        }
    }

    public static func choices(bitDepth: Int, longEdge: Int) -> [Self] {
        bitDepth == 8 && longEdge <= 30_000 ? allCases : [.zip, .lzw, .uncompressed]
    }

    public func apply(to properties: inout [CFString: Any], bitDepth: Int, longEdge: Int, quality: Double) throws {
        guard Self.choices(bitDepth: bitDepth, longEdge: longEdge).contains(self) else {
            throw NSError(domain: "Photons.TIFFCompression", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.tr("tiff.jpegRequirements")])
        }
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFCompression as String] = tag
        properties[kCGImagePropertyTIFFDictionary] = tiff
        if self == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    }
}
