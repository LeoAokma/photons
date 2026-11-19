import AppKit
import PhotonsCore
import PhotonsLocalization

enum DoubleClickZoom {
    static let key = "photons.mac.doubleClickZoom"

    static var target: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: key)
            return PhotoZoomTarget.range.contains(stored) ? stored : 1
        }
        set {
            if PhotoZoomTarget.range.contains(newValue) { UserDefaults.standard.set(newValue, forKey: key) }
        }
    }

    @MainActor static func askForCustomTarget() -> Double? {
        let alert = NSAlert()
        alert.messageText = L10n.tr("ipad.689b97e52438")
        alert.informativeText = L10n.tr("ipad.6211faaf785b")
        alert.addButton(withTitle: L10n.tr("63c73c4730f4"))
        alert.addButton(withTitle: L10n.tr("cameraBodies.cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = (target * 100).formatted(.number.grouping(.never))
        input.setAccessibilityLabel(alert.informativeText)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        while alert.runModal() == .alertFirstButtonReturn {
            if let scale = PhotoZoomTarget.scale(percent: input.stringValue) { return scale }
            NSSound.beep()
            input.selectText(nil)
        }
        return nil
    }
}
