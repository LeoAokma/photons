import Foundation

/// End stops measured on the capture body used for the two CFV 100C lens profiles.
/// Coordinates here are always in the body's unrotated right/up millimetres.
public enum LCCEndStopCalibration: String, Codable {
    case cfv100cMax2026

    static let lens80ID = UUID(uuidString: "A060102A-B2E6-4408-A9C0-F151E042F87D")!

    static func legacyProfile(_ id: UUID, body: PanoramaCameraBody?) -> Self? {
        guard body == nil || body == .alpa12Max else { return nil }
        return id == LCCLensProfile.builtInID || id == lens80ID ? .cfv100cMax2026 : nil
    }

    // Means of the two independently zero-referenced measurements per stop (see Profiles/README.txt).
    var travel: PanoramaShiftRange { .init(left: 18.08, right: 18.16, up: 24.81, down: 18.35) }

    public func position(forReading reading: CGPoint, body: PanoramaCameraBody, orientation: PanoramaBodyOrientation) -> CGPoint {
        guard body == .alpa12Max else { return reading }
        var p = orientation.inverse.rotate(reading)
        switch p.x {
        case -18: p.x = -travel.left
        case 18: p.x = travel.right
        default: break
        }
        switch p.y {
        case -18: p.y = -travel.down
        case 25: p.y = travel.up
        default: break
        }
        return orientation.rotate(p)
    }

    /// At full throw, the registered extremes constrain the origin on that axis. Do not
    /// let the scene-color fit use the general ±0.75 mm search margin to shift it past a stop.
    static func originBounds(centers: [CGPoint], body: PanoramaCameraBody, orientation: PanoramaBodyOrientation,
                             calibration: Self?) -> CGRect? {
        guard let calibration, body == .alpa12Max else {
            return body.travel(at: orientation).opticalOriginBounds(centers: centers)
        }
        let travel = calibration.travel.rotated(orientation)
        guard let bounds = travel.opticalOriginBounds(centers: centers) else { return nil }
        func interval(_ values: [CGFloat], negative: Double, positive: Double, fallback: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
            guard let minValue = values.min(), let maxValue = values.max() else { return fallback }
            let low = maxValue - positive, high = minValue + negative
            // The zero-referenced and independently registered full spans differ by up to
            // 0.14 mm in the calibration scenes. Keep partial-travel axes unconstrained.
            guard abs(high - low) <= 0.25 else { return fallback }
            if low <= high { return low...high }
            let midpoint = (low + high) / 2
            return midpoint...midpoint
        }
        let x = interval(centers.map(\.x), negative: travel.left, positive: travel.right, fallback: bounds.minX...bounds.maxX)
        let y = interval(centers.map(\.y), negative: travel.down, positive: travel.up, fallback: bounds.minY...bounds.maxY)
        return CGRect(x: x.lowerBound, y: y.lowerBound, width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)
    }
}

extension LCCLensProfile {
    /// Legacy files are migrated after integrity verification. Saving or sharing the result
    /// materializes physical positions, including for readers that ignore the optional provenance.
    mutating func resolveLegacyEndStops() {
        guard endStopCalibration == nil,
              let measured = LCCEndStopCalibration.legacyProfile(id, body: cameraBody) else { return }
        var changed = false
        for i in captures.indices {
            let p = measured.position(forReading: CGPoint(x: captures[i].shiftX, y: captures[i].shiftY),
                                      body: .alpa12Max, orientation: .degrees0)
            if p.x != captures[i].shiftX || p.y != captures[i].shiftY { changed = true }
            captures[i].shiftX = p.x
            captures[i].shiftY = p.y
        }
        if changed { endStopCalibration = measured }
    }
}
