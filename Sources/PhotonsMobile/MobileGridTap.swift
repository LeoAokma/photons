#if os(iOS)
import SwiftUI
import UIKit

/// A first tap is useful immediately. A subsequent tap on the same photo opens it;
/// there is no double-tap recognizer that the single tap must wait to fail.
struct MobileGridTapSequence {
    enum Action: Equatable { case select, open, toggleSelection }
    private var lastPhotoID: String?

    mutating func action(photoID: String, tapCount: Int, selectionMode: Bool) -> Action {
        if selectionMode { lastPhotoID = nil; return .toggleSelection }
        if tapCount == 2, lastPhotoID == photoID { lastPhotoID = nil; return .open }
        lastPhotoID = photoID
        return .select
    }
}

struct MobileGridTap: UIGestureRecognizerRepresentable {
    let onTap: (Int) -> Void

    func makeUIGestureRecognizer(context: Context) -> MobileGridTapRecognizer {
        let recognizer = MobileGridTapRecognizer()
        recognizer.numberOfTapsRequired = 1
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: MobileGridTapRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        onTap(recognizer.touchTapCount)
    }
}

/// Keep UIKit's movement, cancellation, multi-touch and scroll arbitration rules.
/// UITouch supplies the system's tap count even though this recognizer completes
/// on each tap, rather than delaying the first one to disambiguate a double tap.
final class MobileGridTapRecognizer: UITapGestureRecognizer {
    static let longPressDuration: TimeInterval = 0.45
    private(set) var touchTapCount = 1
    private var beganTimestamp: TimeInterval = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        beganTimestamp = touches.first?.timestamp ?? 0
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        // The simultaneous long press has already entered selection mode. Releasing
        // that same finger must not toggle the newly selected photo back off.
        if let touch = touches.first, touch.timestamp - beganTimestamp >= Self.longPressDuration {
            state = .failed
            return
        }
        touchTapCount = touches.first?.tapCount ?? 1
        super.touchesEnded(touches, with: event)
    }
}
#endif
