import SwiftUI
import PhotonsLocalization
import PhotonsPanorama

public struct PanoramaShiftHintEditor: View {
    @Binding private var hint: PanoramaShiftHint
    private let suggestion: CGPoint
    private let bodyType: PanoramaCameraBody
    private let orientation: PanoramaBodyOrientation
    private let calibration: LCCEndStopCalibration?

    public init(hint: Binding<PanoramaShiftHint>, suggestion: CGPoint, body: PanoramaCameraBody,
                orientation: PanoramaBodyOrientation, calibration: LCCEndStopCalibration?) {
        _hint = hint
        self.suggestion = suggestion
        bodyType = body
        self.orientation = orientation
        self.calibration = calibration
    }

    public var body: some View {
        let resolved = hint.resolved(body: bodyType, orientation: orientation, calibration: calibration)
        VStack(alignment: .leading, spacing: 8) {
            row($hint.x, horizontal: true, suggestion: suggestion.x, resolved: resolved.x)
            row($hint.y, horizontal: false, suggestion: suggestion.y, resolved: resolved.y)
        }
    }

    private enum Choice { case unknown, reading, negative, positive }

    private func row(_ axis: Binding<PanoramaAxisHint>, horizontal: Bool, suggestion: Double, resolved: Double?) -> some View {
        let selection = Binding<Choice>(get: {
            switch axis.wrappedValue {
            case .unknown: return .unknown
            case .millimeters: return .reading
            case .negativeMaximum: return .negative
            case .positiveMaximum: return .positive
            }
        }, set: { choice in
            switch choice {
            case .unknown: axis.wrappedValue = .unknown
            case .reading: axis.wrappedValue = .millimeters(resolved ?? suggestion)
            case .negative: axis.wrappedValue = .negativeMaximum
            case .positive: axis.wrappedValue = .positiveMaximum
            }
        })
        return HStack {
            Picker(L10n.tr(horizontal ? "98ab61de3e93" : "5e9009b476b1"), selection: selection) {
                Text(L10n.tr("panorama.shift.unknown")).tag(Choice.unknown)
                Text(L10n.tr("panorama.shift.reading")).tag(Choice.reading)
                Text(L10n.tr(horizontal ? "panorama.shift.leftMax" : "panorama.shift.downMax")).tag(Choice.negative)
                Text(L10n.tr(horizontal ? "panorama.shift.rightMax" : "panorama.shift.upMax")).tag(Choice.positive)
            }.pickerStyle(.menu)
            if case .millimeters = axis.wrappedValue {
                TextField("mm", value: Binding(get: {
                    if case .millimeters(let number) = axis.wrappedValue { return number }
                    return suggestion
                }, set: { if $0.isFinite && abs($0) <= 150 { axis.wrappedValue = .millimeters($0) } }),
                format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder).frame(width: 74)
                Text("mm")
            } else if let resolved {
                Text("\(resolved, format: .number.precision(.fractionLength(0...2))) mm")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
