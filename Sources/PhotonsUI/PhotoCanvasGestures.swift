import AppKit

/// Supplies incremental scale factors for both trackpad and direct magnification.
/// The canvas owns mouse click handling so its tool hit tests and click counts still apply.
@MainActor
final class PhotoCanvasGestures: NSObject {
    private let onPinch: (CGFloat, CGPoint) -> Void
    private let onDoubleTap: (CGPoint) -> Void
    private var previousScale: CGFloat = 1

    init(view: NSView, onPinch: @escaping (CGFloat, CGPoint) -> Void,
         onDoubleTap: @escaping (CGPoint) -> Void) {
        self.onPinch = onPinch
        self.onDoubleTap = onDoubleTap
        super.init()
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = .direct
        pinch.delaysMagnificationEvents = true
        view.addGestureRecognizer(pinch)
        let tap = NSClickGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        tap.allowedTouchTypes = .direct
        tap.numberOfTouchesRequired = 1
        tap.buttonMask = 0
        tap.numberOfClicksRequired = 2
        view.addGestureRecognizer(tap)
    }

    @objc private func pinched(_ gesture: NSMagnificationGestureRecognizer) {
        if gesture.state == .began { previousScale = 1 }
        guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended else { return }
        let scale = 1 + gesture.magnification
        guard scale.isFinite, scale > 0 else { return }
        if scale != previousScale { onPinch(scale / previousScale, gesture.location(in: gesture.view)) }
        previousScale = scale
    }

    @objc private func doubleTapped(_ gesture: NSClickGestureRecognizer) {
        onDoubleTap(gesture.location(in: gesture.view))
    }
}
