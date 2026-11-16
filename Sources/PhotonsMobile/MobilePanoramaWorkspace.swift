#if os(iOS)
import SwiftUI
import PhotonsCore
import PhotonsPanorama

/// Physical right/up coordinates are independent of screen size and source pixel dimensions.
enum MobileShiftGeometry {
    static func dragged(_ start: CGPoint, translation: CGSize, pointsPerMM: Double, travel: PanoramaShiftRange) -> CGPoint {
        guard pointsPerMM.isFinite, pointsPerMM > 0 else { return start }
        return CGPoint(x: min(travel.right, max(-travel.left, start.x + translation.width / pointsPerMM)),
                       y: min(travel.up, max(-travel.down, start.y - translation.height / pointsPerMM)))
    }
}

/// Choosing a capture model is required before registration starts.
struct MobilePanoramaFlow: View {
    @ObservedObject var model: MobileWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: PanoramaRegistrationMode?
    var body: some View {
        Group {
            if let mode { MobilePanoramaWorkspace(model: model, mode: mode) }
            else {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("How were these photographs captured?").font(.largeTitle.weight(.semibold))
                        Text("Choose a stitching method before alignment starts.").foregroundStyle(.secondary)
                        choice(.shift, title: "Shift panorama", icon: "arrow.up.and.down.and.arrow.left.and.right", detail: "Lens or back movements on a shift camera. Includes body travel, draggable sensor positions and lens-profile LCC.")
                        choice(.perspective, title: "Perspective panorama", icon: "perspective", detail: "Overlapping views captured by rotating or tilting the camera. Aligns image features using perspective transforms.")
                        Spacer()
                    }.frame(maxWidth: 760).padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.075)).navigationTitle("Panorama").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                }
            }
        }.preferredColorScheme(.dark).tint(.orange)
    }
    private func choice(_ value: PanoramaRegistrationMode, title: String, icon: String, detail: String) -> some View {
        Button { mode = value } label: {
            HStack(spacing: 20) {
                Image(systemName: icon).font(.largeTitle).frame(width: 64)
                VStack(alignment: .leading, spacing: 8) { Text(title).font(.title2.weight(.semibold)); Text(detail).font(.body).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "chevron.right")
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("choose-panorama-\(value.rawValue)")
    }
}

struct MobilePanoramaWorkspace: View {
    @ObservedObject var model: MobileWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    private let photos: [MobilePhoto]
    private let mode: PanoramaRegistrationMode
    @State private var sources: [PanoramaSource] = []
    @State private var positions: [Int: CGPoint] = [:]
    @State private var selectedFrame = 0
    @State private var bodyType = PanoramaCameraBody.alpa12Max
    @State private var orientation = PanoramaBodyOrientation.degrees0
    @State private var options = PanoramaOptions()
    @State private var sensorWidth = 43.8
    @State private var sensorHeight = 32.9
    @State private var manualSensor = false
    @State private var guided = false
    @State private var dirty = true
    @State private var aligning = false
    @State private var export = false
    @State private var profileID: UUID?
    private var sensor: SensorSize { .init(width: sensorWidth, height: sensorHeight, source: manualSensor ? "Manual" : "Source metadata") }
    private var validSensor: Bool { sensorWidth.isFinite && sensorHeight.isFinite && sensorWidth > 0 && sensorHeight > 0 && sensorWidth < 200 && sensorHeight < 200 }

    init(model: MobileWorkspaceModel, mode: PanoramaRegistrationMode) { self.model = model; self.mode = mode; photos = model.selectedPhotos }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if model.busy {
                        HStack {
                            if let fraction = model.progress { ProgressView(value: fraction).frame(width: 130) } else { ProgressView() }
                            Text(model.status).font(.caption).lineLimit(1); Spacer()
                            Button("Cancel task") { model.cancel() }
                        }.padding(12)
                    }
                    if geometry.size.width >= 750 {
                        HStack(spacing: 0) { preview; Divider(); controls.frame(width: 340) }
                    } else {
                        VStack(spacing: 0) { preview.frame(height: geometry.size.height * 0.42); Divider(); controls }
                    }
                    Divider()
                    HStack {
                        if let plan = model.plan { Text("\(Int(plan.outputSize.width)) × \(Int(plan.outputSize.height)) · \(photos.count) photographs").font(.caption) }
                        Spacer()
                        Button("Stitch / Export") { export = true }
                            .buttonStyle(.borderedProminent).disabled(model.plan == nil || dirty || model.busy)
                            .accessibilityIdentifier("panorama-export")
                    }.padding(14)
                }.background(Color(white: 0.075))
            }
            .navigationTitle(mode == .shift ? "Shift panorama" : "Perspective panorama").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if model.busy { model.cancel() }; dismiss() }.accessibilityIdentifier("close-panorama")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(model.hdr ? "HDR" : "SDR") { model.toggleHDR() }.disabled(model.busy).accessibilityIdentifier("panorama-display-mode")
                }
            }
        }.preferredColorScheme(.dark).tint(.orange)
        .task {
            model.plan = nil; model.manifest = nil; model.frame = nil; model.error = nil
            do {
                sources = try await model.engine.sourceInfo(photos)
                if let known = sources.first?.sensor { sensorWidth = known.width; sensorHeight = known.height }
                else { manualSensor = true }
                positions = Dictionary(uniqueKeysWithValues: photos.indices.map { ($0, CGPoint.zero) })
                profileID = model.profiles.first?.id
                align()
            } catch { model.error = error.localizedDescription }
        }
        .onChange(of: model.busy) { _,busy in
            if !busy {
                if aligning {
                    aligning = false
                    if model.error == nil, let plan = model.plan { accept(plan) }
                } else if let plan = model.plan, let lcc = plan.lccState {
                    positions = framePositions(plan, offset: lcc.offsetMM)
                }
            }
        }
        .sheet(isPresented: $export) {
            NavigationStack {
                MobileExportSheet(model: model, onExport: { dismiss() })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { export = false } } }
            }.preferredColorScheme(.dark)
        }
        .alert("Panorama", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var preview: some View {
        ZStack {
            Color(white: 0.055)
            if model.plan != nil, let image = model.frame?.image {
                MobilePhotoCanvas(image: image, hdr: model.hdr, identity: "panorama-workspace")
                    .padding(20).accessibilityIdentifier("panorama-preview")
                if dirty { Text("Positions changed · update alignment to refresh this preview").font(.caption).padding(12).background(.ultraThinMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .bottom).padding() }
            } else {
                ContentUnavailableView("Panorama preview", systemImage: "pano", description: Text(model.busy ? "Aligning the selected photographs…" : "Drag the source frames or enter measured positions, then update alignment."))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if mode == .shift {
                Text("SHIFT PANORAMA").font(.headline)
                Picker("Camera body", selection: $bodyType) { ForEach(PanoramaCameraBody.allCases) { Text($0.name).tag($0) } }
                    .onChange(of: bodyType) { _,_ in dirty = true }
                Picker("Body orientation", selection: $orientation) { ForEach(PanoramaBodyOrientation.allCases) { Text("\($0.rawValue)°").tag($0) } }
                    .pickerStyle(.segmented).onChange(of: orientation) { _,_ in dirty = true }
                Text(bodyType.travel(at: orientation).summary).font(.caption).foregroundStyle(.secondary)
                if validSensor {
                    MobileDraggablePositions(names: photos.map(\.name), sensor: sensor, travel: bodyType.travel(at: orientation),
                        positions: $positions, selected: $selectedFrame, changed: { guided = true; dirty = true })
                        .frame(height: 310)
                }
                Text("Dashed outline: total sensor travel. Cross: body zero. Drag a frame to set an approximate position; update alignment to verify the overlap.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(photos.enumerated()), id: \.offset) { i,photo in
                    Button { selectedFrame = i } label: {
                        HStack {
                            if let image = model.thumbnails[photo.id]?.image { Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 42, height: 40) }
                            VStack(alignment: .leading) {
                                Text(photo.name).font(.caption.weight(.semibold))
                                let point = positions[i] ?? .zero
                                Text(String(format: "X %+.1f · Y %+.1f mm", point.x, point.y)).font(.caption.monospacedDigit())
                            }
                            Spacer(); if selectedFrame == i { Image(systemName: "checkmark.circle.fill") }
                        }.padding(8).background(selectedFrame == i ? Color.orange.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityIdentifier("select-frame-\(i)")
                }
                if photos.indices.contains(selectedFrame) {
                    Text("Selected frame position").font(.caption.weight(.semibold))
                    MobilePositionFields(position: Binding(get: { positions[selectedFrame] ?? .zero }, set: { positions[selectedFrame] = $0; guided = true; dirty = true }))
                }
                Toggle("Use position guidance", isOn: $guided).accessibilityIdentifier("position-guidance").onChange(of: guided) { _,_ in dirty = true }
                Text(guided ? "Positions guide matching near your measurements; image features still determine the final alignment." : "Automatic alignment shows relative positions; the absolute optical center has not been confirmed.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("PERSPECTIVE PANORAMA").font(.headline)
                    if let plan = model.plan { MobilePositionDiagram(plan: plan).frame(height: 280) }
                    Text("Image features determine the perspective alignment. This preview uses a planar projection; very wide or 360° panoramas are not yet supported.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Alignment options") {
                    if mode == .shift {
                    Toggle("Override sensor dimensions", isOn: $manualSensor).onChange(of: manualSensor) { _,enabled in
                        if !enabled, let known = sources.first?.sensor { sensorWidth = known.width; sensorHeight = known.height }; dirty = true
                    }
                    if manualSensor {
                        LabeledContent("Width (mm)") { TextField("Width", value: $sensorWidth, format: .number) }
                        LabeledContent("Height (mm)") { TextField("Height", value: $sensorHeight, format: .number) }
                    } else { Text(String(format: "%.2f × %.2f mm", sensorWidth, sensorHeight)).font(.caption) }
                    }
                    Toggle("Match exposure", isOn: $options.matchExposure)
                    Toggle("Avoid moving subjects", isOn: $options.avoidMotion)
                    Slider(value: $options.seamSoftness, in: 0...20) { Text("Seam softness") }
                }.onChange(of: options) { _,_ in dirty = true }
                    .onChange(of: sensorWidth) { _,_ in dirty = true }.onChange(of: sensorHeight) { _,_ in dirty = true }
                Button("Update alignment", action: align).buttonStyle(.borderedProminent)
                    .disabled(model.busy || !validSensor || sources.count < 2).accessibilityIdentifier("align-panorama")
                Divider()
                if mode == .shift {
                Text("LCC CORRECTION").font(.caption.weight(.semibold))
                Picker("Lens profile", selection: $profileID) {
                    Text("Choose a profile").tag(UUID?.none)
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Apply lens profile") {
                    guard let profileID, let plan = model.plan else { return }
                    let offset = guided ? PanoramaPositionReference(sourceIndex: selectedFrame, positionMM: positions[selectedFrame] ?? .zero).profileOffset(in: plan, sensor: sensor) : nil
                    model.correctPanorama(profileID: profileID, offset: offset, body: bodyType, orientation: orientation)
                }.disabled(model.busy || dirty || model.plan == nil || profileID == nil).accessibilityIdentifier("panorama-lcc")
                if let lcc = model.plan?.lccState { Label(lcc.profileName, systemImage: "checkmark.seal"); Text(String(format: "Coverage %.1f%%", lcc.coveredFraction * 100)).font(.caption) }
                if let note = model.lccPositionNote { Text(note).font(.caption).foregroundStyle(.orange) }
                } else { Text(PanoramaRegistrationMode.perspectiveLCCNotice).font(.caption).foregroundStyle(.secondary) }
                if let histogram = model.frame?.histogram { MobileHistogram(histogram: histogram).frame(height: 100) }
            }.padding(18).disabled(model.busy)
        }.background(Color(white: 0.105)).accessibilityIdentifier("panorama-controls")
    }
    private func align() {
        guard validSensor, !model.busy else { return }
        aligning = true; model.error = nil; dirty = true
        model.stitch(options: options, positions: mode == .shift && guided ? positions : [:], sensor: mode == .shift && manualSensor ? sensor : nil, registrationMode: mode)
    }
    private func accept(_ plan: PanoramaPlan) {
        let anchor = mode == .shift && guided ? PanoramaPositionReference(sourceIndex: selectedFrame, positionMM: positions[selectedFrame] ?? .zero) : nil
        let offset = anchor?.profileOffset(in: plan, sensor: sensor) ?? .zero
        positions = framePositions(plan, offset: offset)
        // Measured absolute reference survives an uncorrected export for later LCC.
        if anchor != nil { model.manifest = PanoramaManifest(plan: plan, offsetMM: offset, sensor: sensor, bodyOrientation: orientation, cameraBody: bodyType) }
        dirty = false
    }
    private func framePositions(_ plan: PanoramaPlan, offset: CGPoint) -> [Int: CGPoint] {
        Dictionary(uniqueKeysWithValues: plan.sources.indices.map { i in
            let r = plan.sensorRect(i)
            return (i, CGPoint(x: (r.midX - plan.size.width / 2) * sensor.width / r.width - offset.x,
                               y: (plan.size.height / 2 - r.midY) * sensor.height / r.height - offset.y))
        })
    }
}

struct MobileDraggablePositions: View {
    let names: [String]
    let sensor: SensorSize
    let travel: PanoramaShiftRange
    @Binding var positions: [Int: CGPoint]
    @Binding var selected: Int
    let changed: () -> Void
    @State private var dragStart: CGPoint?
    var body: some View {
        GeometryReader { geometry in
            let bounds = travel.coverage(sensor: sensor, centered: false).insetBy(dx: -4, dy: -4)
            let scale = min(geometry.size.width / bounds.width, geometry.size.height / bounds.height)
            let x0 = (geometry.size.width - bounds.width * scale) / 2 - bounds.minX * scale
            let y0 = (geometry.size.height - bounds.height * scale) / 2 - bounds.minY * scale
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.2)
                let coverage = travel.coverage(sensor: sensor, centered: false)
                Rectangle().stroke(.gray, style: StrokeStyle(lineWidth: 1, dash: [5,4]))
                    .frame(width: coverage.width * scale, height: coverage.height * scale)
                    .offset(x: x0 + coverage.minX * scale, y: y0 + coverage.minY * scale)
                Rectangle().stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2,3]))
                    .frame(width: sensor.width * scale, height: sensor.height * scale)
                    .offset(x: x0 - sensor.width * scale / 2, y: y0 - sensor.height * scale / 2)
                Image(systemName: "plus").font(.caption).position(x: x0, y: y0)
                ForEach(names.indices, id: \.self) { i in
                    let point = positions[i] ?? .zero
                    let color = travel.contains(point, tolerance: 0.1) ? [Color.cyan, .purple, .green, .pink][i % 4] : .orange
                    Rectangle().fill(color.opacity(selected == i ? 0.25 : 0.1))
                        .overlay(Rectangle().stroke(color, lineWidth: selected == i ? 2.5 : 1))
                        .overlay(Text(names[i]).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5).padding(4), alignment: .top)
                        .frame(width: sensor.width * scale, height: sensor.height * scale)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            selected = i
                            if dragStart == nil { dragStart = point }
                            positions[i] = MobileShiftGeometry.dragged(dragStart ?? point, translation: value.translation, pointsPerMM: scale, travel: travel)
                            changed()
                        }.onEnded { _ in dragStart = nil })
                        .onTapGesture { selected = i }
                        .offset(x: x0 + (point.x - sensor.width / 2) * scale, y: y0 + (-point.y - sensor.height / 2) * scale)
                        .zIndex(selected == i ? 2 : 1)
                        .accessibilityElement(children: .ignore).accessibilityLabel(names[i])
                        .accessibilityAddTraits(.isButton).accessibilityAction { selected = i }
                        .accessibilityValue(String(format: "X %.1f, Y %.1f millimeters", point.x, point.y))
                        .accessibilityIdentifier("shift-frame-\(i)")
                }
            }.clipped().clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityElement(children: .contain).accessibilityIdentifier("body-shift-diagram")
    }
}
#endif
