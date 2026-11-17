#if os(iOS)
import Foundation
import PhotonsCore
import PhotonsLocalization

/// Detail output is a viewport, but today's graph still uploads the complete decoded source.
/// Budget both allocations before decoding. Never change the user's zoom geometry to do so.
struct MobileDetailSizing {
    let request: MobileDetailRequest
    let longEdge: Int
    let scale: Double

    static func plan(source: ImageSize, output: ImageSize, request: MobileDetailRequest,
                     textureLimit: Int, availableBytes: Double) throws -> MobileDetailSizing {
        let r = request.rect
        guard source.width > 0, source.height > 0, output.width > 0, output.height > 0,
              request.scale.isFinite, request.scale > 0, availableBytes.isFinite,
              [r.origin.x,r.origin.y,r.width,r.height].allSatisfy({ $0.isFinite }),
              r.width > 0, r.height > 0 else { throw unavailable }
        let rect = r.intersection(CGRect(x: 0,y: 0,width: 1,height: 1))
        guard !rect.isNull, !rect.isEmpty else { throw unavailable }
        let requested = min(1,request.scale)
        // Reserve room for cached stages, while keeping a detail job below 2 GiB even
        // when the simulator reports the host Mac's much larger memory allowance.
        let budget = min(2 * 1024 * 1024 * 1024, max(0,availableBytes) * 0.6)
        let reserve = 160.0 * 1024 * 1024
        // Stable rungs let panning reuse the decoded source instead of continuously
        // changing scale as the amount of free memory fluctuates slightly.
        let scales = [requested] + [0.75,0.5,0.375,0.25,0.1875,0.125,0.09375,0.0625,0.03125,0.015625].filter { $0 < requested }
        for scale in scales {
            // RAW output can include a few extra border pixels beyond its metadata size.
            // The decoder also validates the actual extent before Metal allocation.
            let edge = max(1,Int(floor(Double(max(source.width,source.height)) * scale)))
            let width = ceil(Double(output.width) * rect.width * scale) + 128
            let height = ceil(Double(output.height) * rect.height * scale) + 128
            let sourceBytes = Double(source.width) * Double(source.height) * scale * scale * 64
            let windowBytes = width * height * 96
            guard edge <= textureLimit - 64, width <= Double(textureLimit), height <= Double(textureLimit),
                  sourceBytes + windowBytes + reserve <= budget else { continue }
            return .init(request: .init(rect: rect,scale: scale),longEdge: edge,scale: scale)
        }
        throw unavailable
    }

    private static var unavailable: MobileError {
        .message(L10n.tr("ipad.zoom.detailUnavailable"))
    }
}
#endif
