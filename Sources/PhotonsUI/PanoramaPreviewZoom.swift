import CoreGraphics
import PhotonsCore

/// The centre is normalized in the final stitch. Geometry and gesture points use a top-left origin.
struct PanoramaPreviewZoom: Equatable {
    var scale: CGFloat?
    var center = CGPoint(x: 0.5, y: 0.5)

    func fit(_ pixels: CGSize, in view: CGSize, backing: CGFloat) -> CGFloat {
        min(view.width / pixels.width, view.height / pixels.height) * backing
    }

    func imageFrame(_ pixels: CGSize, in view: CGSize, backing: CGFloat) -> CGRect {
        let ratio = (scale ?? fit(pixels, in: view, backing: backing)) / backing
        let size = CGSize(width: pixels.width * ratio, height: pixels.height * ratio)
        func origin(_ length: CGFloat, _ available: CGFloat, _ center: CGFloat) -> CGFloat {
            if length <= available { return (available - length) / 2 }
            return min(0, max(available - length, available / 2 - center * length))
        }
        return CGRect(x: origin(size.width, view.width, center.x),
                      y: origin(size.height, view.height, center.y), width: size.width, height: size.height)
    }

    mutating func magnify(to requested: CGFloat, at point: CGPoint, pixels: CGSize, in view: CGSize, backing: CGFloat) {
        guard requested.isFinite, requested > 0 else { return }
        let old = imageFrame(pixels, in: view, backing: backing)
        let fit = fit(pixels, in: view, backing: backing)
        scale = min(max(requested, min(PhotoZoomTarget.range.lowerBound, fit)), max(PhotoZoomTarget.range.upperBound, fit))
        let size = imageFrame(pixels, in: view, backing: backing).size
        center = CGPoint(x: (point.x - old.minX) / old.width + (view.width / 2 - point.x) / size.width,
                         y: (point.y - old.minY) / old.height + (view.height / 2 - point.y) / size.height)
        constrainCenter(pixels, in: view, backing: backing)
    }

    mutating func pan(by delta: CGPoint, pixels: CGSize, in view: CGSize, backing: CGFloat) {
        guard scale != nil else { return }
        let frame = imageFrame(pixels, in: view, backing: backing)
        center = CGPoint(x: (view.width / 2 - frame.minX - delta.x) / frame.width,
                         y: (view.height / 2 - frame.minY - delta.y) / frame.height)
        constrainCenter(pixels, in: view, backing: backing)
    }

    private mutating func constrainCenter(_ pixels: CGSize, in view: CGSize, backing: CGFloat) {
        let frame = imageFrame(pixels, in: view, backing: backing)
        center = CGPoint(x: (view.width / 2 - frame.minX) / frame.width,
                         y: (view.height / 2 - frame.minY) / frame.height)
    }
}
