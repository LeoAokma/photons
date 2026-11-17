import Foundation
import Metal

/// Invalid Metal texture descriptors can abort instead of returning nil. Validate source
/// dimensions before asking Metal to allocate; callers can then choose a smaller decode.
public enum MetalTextureLimits {
    public static func maximum2DDimension(for device: MTLDevice) -> Int {
        #if targetEnvironment(simulator)
        // MTLSimDevice exposes 8192 even on a host whose GPU accepts larger textures.
        return 8192
        #else
        // Apple Metal Feature Set Tables: Apple10 = 32768; Apple3–9 / Mac2 = 16384.
        // Raw value keeps this source buildable with SDKs predating the Apple10 spelling.
        if let apple10 = MTLGPUFamily(rawValue: 1010), device.supportsFamily(apple10) { return 32768 }
        if device.supportsFamily(.apple3) || device.supportsFamily(.mac2) { return 16384 }
        return 8192
        #endif
    }

    public static func validate(width: Int, height: Int, device: MTLDevice) throws {
        let maximum = maximum2DDimension(for: device)
        guard width > 0, height > 0, width <= maximum, height <= maximum else {
            throw TextureDimensionError(width: width, height: height, maximum: maximum)
        }
    }
}

public struct TextureDimensionError: LocalizedError {
    public let width: Int
    public let height: Int
    public let maximum: Int
    public var errorDescription: String? {
        "Image size \(width) × \(height) exceeds the supported texture dimensions (\(maximum) × \(maximum))."
    }
}
