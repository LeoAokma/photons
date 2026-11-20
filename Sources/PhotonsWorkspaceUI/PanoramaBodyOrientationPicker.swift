import PhotonsLocalization
import PhotonsPanorama
import SwiftUI

/// Body placement in the panorama, LCC correction and profile creation workspaces.
public struct PanoramaBodyOrientationPicker: View {
    @Environment(\.locale) private var interfaceLocale
    private let cameraBody: PanoramaCameraBody
    @Binding private var selection: PanoramaBodyOrientation

    public init(cameraBody: PanoramaCameraBody, selection: Binding<PanoramaBodyOrientation>) {
        self.cameraBody = cameraBody
        _selection = selection
    }

    private var orientations: [PanoramaBodyOrientation] {
        #if os(macOS)
        cameraBody.orientations
        #else
        PanoramaBodyOrientation.allCases
        #endif
    }

    public var body: some View {
        let _ = interfaceLocale // Refresh plain translated labels after an in-app language change.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(orientations) { angle in
                    let selected = selection == angle
                    let placement = cameraBody.placementLabel(angle)
                    let outline = RoundedRectangle(cornerRadius: 8)
                    Button { selection = angle } label: {
                        VStack(spacing: 4) {
                            diagram(for: angle, selected: selected).frame(height: 42)
                            caption(angle, placement: placement)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8).padding(.horizontal, 3)
                        .frame(maxWidth: .infinity)
                        .background(selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: outline)
                        .overlay(outline.stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                                lineWidth: selected ? 1.5 : 0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("c0a3dfc3ae3e", String(angle.rawValue), placement))
                    .accessibilityValue(L10n.tr(selected ? "3f4ebc4aad97" : "0e0c21de6988"))
                    .accessibilityIdentifier("panorama.body.orientation.\(angle.rawValue)")
                }
            }
            Text(L10n.tr("444399a3f9ce")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func caption(_ angle: PanoramaBodyOrientation, placement: String) -> some View {
        #if os(macOS)
        Text("\(angle.rawValue)° \(placement)")
            .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
        #else
        Text("\(angle.rawValue)°").font(.caption.weight(.semibold))
        Text(placement).font(.system(size: 10)).lineLimit(2).minimumScaleFactor(0.8).frame(height: 26)
        #endif
    }

    private func diagram(for angle: PanoramaBodyOrientation, selected: Bool) -> some View {
        Canvas { context, size in
            // A small footprint keeps a single-axis body's outline visible.
            let range = cameraBody.travel(at: angle).coverage(sensor: .init(width: 12, height: 12, source: "Diagram"), centered: false)
            let scale = min(min(52, max(1, size.width - 6)) / range.width, 34 / range.height)
            let rect = CGRect(x: (size.width - range.width * scale) / 2, y: (size.height - range.height * scale) / 2,
                              width: range.width * scale, height: range.height * scale)
            let zero = CGPoint(x: rect.minX - range.minX * scale, y: rect.minY - range.minY * scale)
            let color: Color = selected ? .accentColor : .primary
            context.fill(Path(rect), with: .color(color.opacity(0.08)))
            context.stroke(Path(rect), with: .color(color.opacity(0.8)), lineWidth: 1.3)
            var cross = Path()
            cross.move(to: CGPoint(x: zero.x - 4, y: zero.y))
            cross.addLine(to: CGPoint(x: zero.x + 4, y: zero.y))
            cross.move(to: CGPoint(x: zero.x, y: zero.y - 4))
            cross.addLine(to: CGPoint(x: zero.x, y: zero.y + 4))
            context.stroke(cross, with: .color(color), lineWidth: 1.3)
        }
        .accessibilityHidden(true)
    }
}
