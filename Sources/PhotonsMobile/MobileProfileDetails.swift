#if os(iOS)
import SwiftUI
import PhotonsPanorama
import PhotonsLocalization

struct MobileProfileDetails: View {
    let engine: MobileEngine
    let id: UUID
    @State private var profile: LCCLensProfile?
    @State private var error: String?
    var body: some View {
        Form {
            if let profile {
                Section("Profile information") {
                    LabeledContent("Name",value: profile.name)
                    LabeledContent("Camera",value: profile.camera)
                    if let aperture = profile.aperture { LabeledContent("Aperture",value: String(format: "f/%g",aperture)) }
                    LabeledContent("Calibration body",value: LCCProfileSummary(profile).calibrationBody?.name ?? "Not recorded")
                    LabeledContent("Created") { Text(profile.createdAt,style: .date) }
                    LabeledContent("Profile version",value: "\(profile.schemaVersion)")
                    LabeledContent("Calibration frames",value: "\(profile.captures.count)")
                    Text(L10n.tr("lcc.profile.compatibility")).font(.caption).foregroundStyle(.secondary)
                    ShareLink(item: LCCProfileStore().url(for: id)) { Label("Share profile",systemImage: "square.and.arrow.up") }
                }
                if !profile.notes.isEmpty { Section("Notes") { Text(profile.notes).textSelection(.enabled) } }
                ForEach(profile.orientations) { orientation in
                    let captures = profile.captures(for: orientation)
                    Section {
                        MobileProfileCoverage(captures: captures).frame(height: 190)
                            .accessibilityIdentifier("profile-coverage-\(orientation.rawValue)")
                        Text(String(format: "Shift X %+.1f…%+.1f mm · Y %+.1f…%+.1f mm",
                            captures.map(\.shiftX).min() ?? 0,captures.map(\.shiftX).max() ?? 0,
                            captures.map(\.shiftY).min() ?? 0,captures.map(\.shiftY).max() ?? 0)).font(.caption.monospacedDigit())
                        Text("Rectangles show measured sensor coverage; dots mark capture centers. X points right and Y points up.").font(.caption).foregroundStyle(.secondary)
                        ForEach(captures) { capture in
                            DisclosureGroup {
                                captureDetails(capture)
                            } label: { Text(capture.filename).lineLimit(2) }
                            .accessibilityIdentifier("profile-capture-\(capture.id.uuidString)")
                        }
                    } header: { Text("\(orientation.title) · \(captures.count) frames") }
                }
                Section {
                    Text(L10n.tr("462dcac8baeb"))
                    Text(L10n.tr("89e848ef8755"))
                }.font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Text(error).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            } else { ProgressView("Loading profile…") }
        }
        .navigationTitle(profile?.name ?? "Lens profile details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await load() }
    }
    private func load() async {
        do { profile = try await engine.profile(id); error = nil }
        catch { self.error = error.localizedDescription }
    }
    @ViewBuilder private func captureDetails(_ capture: LCCProfileCapture) -> some View {
        LabeledContent("Shift position",value: String(format: "X %+.1f · Y %+.1f mm",capture.shiftX,capture.shiftY))
        LabeledContent("Sensor size",value: String(format: "%.2f × %.2f mm",capture.sensorWidth,capture.sensorHeight))
        LabeledContent("Pixel dimensions",value: "\(capture.pixelWidth) × \(capture.pixelHeight)")
        if let iso = capture.iso { LabeledContent("ISO",value: String(format: "%g",iso)) }
        if let seconds = capture.exposureSeconds { LabeledContent("Exposure time",value: String(format: "%.6g s",seconds)) }
        if let date = capture.capturedAt { LabeledContent("Captured",value: date) }
        if let body = capture.bodyOrientation { LabeledContent("Body orientation",value: "\(body.rawValue)°") }
        gridDetails(capture.grid,title: "Measurement grid")
        if let grid = capture.renderGrid { gridDetails(grid,title: "Render grid") }
    }
    @ViewBuilder private func gridDetails(_ grid: LCCMeasurementGrid,title: String) -> some View {
        LabeledContent(title,value: "\(grid.width) × \(grid.height) · \(grid.channels.joined(separator: "/"))")
        Text(grid.space).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

struct MobileProfileCoverage: View {
    let captures: [LCCProfileCapture]
    static func bounds(_ captures: [LCCProfileCapture]) -> CGRect { captures.reduce(.null) { $0.union($1.fieldRect) } }
    var body: some View {
        Canvas { context,size in
            let bounds = Self.bounds(captures)
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
            let scale = min((size.width-24)/bounds.width,(size.height-24)/bounds.height)
            let origin = CGPoint(x: (size.width-bounds.width*scale)/2,y: (size.height-bounds.height*scale)/2)
            for capture in captures {
                let field = capture.fieldRect
                let rect = CGRect(x: origin.x+(field.minX-bounds.minX)*scale,y: origin.y+(bounds.maxY-field.maxY)*scale,
                                  width: field.width*scale,height: field.height*scale)
                context.fill(Path(rect),with: .color(.cyan.opacity(0.045)))
                context.stroke(Path(rect),with: .color(.cyan.opacity(0.4)),lineWidth: 0.8)
                context.fill(Path(ellipseIn: CGRect(x: rect.midX-2,y: rect.midY-2,width: 4,height: 4)),with: .color(.primary.opacity(0.7)))
            }
        }.background(.quaternary,in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Lens calibration coverage")
    }
}
#endif
