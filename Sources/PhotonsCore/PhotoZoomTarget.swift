import Foundation

/// Numeric zoom is measured in display pixels per source pixel on both platforms.
public enum PhotoZoomTarget {
    public static let presets = [0.5, 1.0, 2.0]
    public static let range = 0.1...8.0

    public static func scale(percent text: String, locale: Locale = .current) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard let percent = Double(input), (10...800).contains(percent) else { return nil }
        return percent / 100
    }
}
