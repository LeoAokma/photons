import Foundation

public enum PanoramaAxisHint: Equatable, Sendable {
    case unknown
    case millimeters(Double)
    case negativeMaximum
    case positiveMaximum

    fileprivate func value(negative: Double, positive: Double) -> Double? {
        switch self {
        case .unknown: return nil
        case .millimeters(let value): return value.isFinite ? value : nil
        case .negativeMaximum: return -negative
        case .positiveMaximum: return positive
        }
    }
}

/// Keep an end stop symbolic until the current body, orientation and lens profile are known.
public struct PanoramaShiftHint: Equatable, Sendable {
    public var x: PanoramaAxisHint
    public var y: PanoramaAxisHint

    public init(x: PanoramaAxisHint = .unknown, y: PanoramaAxisHint = .unknown) {
        self.x = x
        self.y = y
    }

    public mutating func recordDrag(from start: CGPoint, to end: CGPoint) {
        if start.x != end.x { x = .millimeters(end.x) }
        if start.y != end.y { y = .millimeters(end.y) }
    }

    public func resolved(body: PanoramaCameraBody, orientation: PanoramaBodyOrientation,
                         calibration: LCCEndStopCalibration?) -> PanoramaShiftPosition {
        let travel = (body == .alpa12Max ? calibration?.travel.rotated(orientation) : nil)
            ?? body.travel(at: orientation)
        return .init(x: x.value(negative: travel.left, positive: travel.right),
                     y: y.value(negative: travel.down, positive: travel.up))
    }
}

/// Right/up in millimetres at the API boundary. Missing coordinates carry no evidence.
public struct PanoramaShiftPosition: Equatable, Sendable {
    public let x: Double?
    public let y: Double?

    public init(x: Double? = nil, y: Double? = nil) {
        self.x = x.flatMap { $0.isFinite ? $0 : nil }
        self.y = y.flatMap { $0.isFinite ? $0 : nil }
    }

    public init(_ point: CGPoint) { self.init(x: point.x, y: point.y) }

    public var point: CGPoint? {
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }

    func difference(from other: Self, pixelsPerMM: CGSize) -> Self {
        Self(x: x.flatMap { b in other.x.map { (b - $0) * pixelsPerMM.width } },
             y: y.flatMap { b in other.y.map { -(b - $0) * pixelsPerMM.height } })
    }
}
