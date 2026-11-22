import PhotonsLocalization
import AppKit
import PhotonsFileAccess
import SwiftUI
import UniformTypeIdentifiers
import PhotonsPanorama
import PhotonsWorkspaceUI

@MainActor
public final class PanoramaWindowController: NSWindowController, NSWindowDelegate {
    private let model: PanoramaWindowModel
    public var onClose: (() -> Void)?
    public var onExported: (URL,@escaping(String?)->Void)->Void {
        get {model.onExported} set {model.onExported=newValue}
    }
    public init(urls: [URL]) {
        model = PanoramaWindowModel(urls:urls)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1240,height:820),
                              styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = L10n.tr("8b92765d86d0"); window.minSize = NSSize(width:980,height:690); window.isReleasedWhenClosed = false
        super.init(window:window)
        window.delegate = self; model.window = window
        window.contentView = NSHostingView(rootView:PanoramaWorkspace(model:model))
        window.center()
    }
    public required init?(coder:NSCoder) { fatalError("no nib") }
    public func windowWillClose(_ notification:Notification) { model.cancel(); onClose?() }
}

@MainActor
final class PanoramaWindowModel: ObservableObject {
    let urls: [URL]
    private let sourceAccess: [FileAccess]
    weak var window: NSWindow?
    @Published var choosingMode = true
    @Published private(set) var registrationMode:PanoramaRegistrationMode = .shift
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var plan: PanoramaPlan?
    @Published var tone = PanoramaToneSettings.panoramaDefault
    @Published var options = PanoramaOptions()
    var onExported: (URL,@escaping(String?)->Void)->Void = {_,done in done(nil)}
    @Published var cameraBody:PanoramaCameraBody = .alpa12Max
    @Published var bodyOrientation:PanoramaBodyOrientation = .degrees0
    @Published var sensorChoice = 0
    @Published var sensorWidth = 43.8
    @Published var sensorHeight = 32.9
    @Published var positionReference:PanoramaPositionReference?
    @Published var shiftHints: [Int: PanoramaShiftHint] = [:]
    private var appliedRegistrationHints: [Int: PanoramaShiftPosition] = [:]
    @Published var alignmentNeedsUpdate=false
    @Published var estimatedReference:PanoramaPositionReference?
    @Published var positionExplanation=""
    @Published var editingPosition:Int?
    @Published var lccCount = 0
    @Published var lensProfiles: [LCCProfileSummary] = []
    @Published var selectedLensProfileID = UserDefaults.standard.string(forKey:"Photons.panorama.lensProfileID") ?? LCCLensProfile.builtInID.uuidString
    @Published var profileStatus = L10n.tr("b3ef060e30d6")
    @Published var lccEnabled=false
    @Published var cropToLCC=false
    @Published private(set) var hasManualLCCPosition = false
    @Published var lccOffset=CGPoint.zero
    @Published var exposureEV=0.0
    @Published var automaticLCCWB=true
    @Published var lccTemperature=5500.0
    @Published var lccTint=0.0
    @Published var protectHighlights=true
    private var lccSession:LCCEditingSession?
    private(set) var alignmentWindow:LCCAlignmentWindowController?
    private var lccWindow: LCCWindowController?
    private var exportWindow: PanoramaExportController?
    private var cancellation = PanoramaCancellation()
    private let queue = DispatchQueue(label:"Photons.panorama",qos:.userInitiated)
    private let profileStore: LCCProfileStore
    init(urls: [URL], profileStore: LCCProfileStore = LCCProfileStore()) {
        self.profileStore = profileStore
        sourceAccess = urls.map { FileAccessStore.shared.access(to: $0) }
        self.urls = sourceAccess.map(\.url); refreshLCC()
    }
    func cancel() { cancellation.cancel(); alignmentWindow?.close(); exportWindow?.dismiss() }
    func setBody(_ body:PanoramaCameraBody) {
        cameraBody=body;bodyOrientation=body.canonicalOrientation(bodyOrientation);bodyPlacementChanged()
    }
    func setBodyOrientation(_ orientation:PanoramaBodyOrientation) {
        guard orientation != bodyOrientation else {return}
        bodyOrientation=orientation;bodyPlacementChanged()
    }
    private func bodyPlacementChanged() {
        alignmentWindow?.close();selectLensProfile();updateHintStatus()
        if positionReference == nil && !hasManualLCCPosition { estimatedReference=nil; positionExplanation=""; lccOffset = .zero }
        if lccEnabled {changeLCC(automaticallyLocate:true)}
    }
    var endStopCalibration: LCCEndStopCalibration? {
        lensProfiles.first { $0.id.uuidString == selectedLensProfileID }?.resolvedEndStops
    }
    var resolvedHints: [Int: PanoramaShiftPosition] {
        shiftHints.mapValues { $0.resolved(body: cameraBody, orientation: bodyOrientation, calibration: endStopCalibration) }
    }
    private var registrationHints: [Int: PanoramaShiftPosition] {
        let all = resolvedHints
        return all.values.compactMap(\.x).count >= 2 || all.values.compactMap(\.y).count >= 2 ? all : [:]
    }
    func updateHintStatus() {
        alignmentNeedsUpdate = registrationHints != appliedRegistrationHints
    }
    private var measuredReference: PanoramaPositionReference? {
        guard let reference = positionReference else { return nil }
        let point = resolvedHints[reference.sourceIndex]?.point ?? reference.positionMM
        return .init(sourceIndex: reference.sourceIndex, positionMM: point)
    }
    private func reference(at offset: CGPoint, in plan: PanoramaPlan, sensor: SensorSize) -> PanoramaPositionReference {
        let r = plan.sensorRect(0)
        return PanoramaPositionReference(sourceIndex: 0, positionMM: CGPoint(
            x: (r.midX - plan.size.width / 2) * sensor.width / r.width - offset.x,
            y: (plan.size.height / 2 - r.midY) * sensor.height / r.height - offset.y))
    }
    var overviewReference: PanoramaPositionReference? {
        if hasManualLCCPosition, let plan, let sensor { return reference(at: lccOffset, in: plan, sensor: sensor) }
        return measuredReference ?? estimatedReference
    }
    func usePositionReference() {
        guard let reference = measuredReference, let plan, let sensor else { return }
        hasManualLCCPosition = false
        estimatedReference = nil
        positionExplanation = ""
        lccOffset = reference.profileOffset(in: plan, sensor: sensor)
        changeLCC()
    }
    func setShiftHint(index: Int, hint: PanoramaShiftHint, asReference: Bool) {
        alignmentWindow?.close()
        shiftHints[index] = hint == PanoramaShiftHint() ? nil : hint
        if asReference, let point = resolvedHints[index]?.point {
            hasManualLCCPosition = false
            positionReference = .init(sourceIndex: index, positionMM: point)
        } else if positionReference?.sourceIndex == index {
            positionReference = nil
        }
        estimatedReference = nil
        positionExplanation = ""
        if !hasManualLCCPosition { lccOffset = .zero }
        updateHintStatus()
        changeLCC(automaticallyLocate: true)
    }
    func moveFrame(_ index: Int, from start: CGPoint, to end: CGPoint) {
        guard start != end else { return }
        var hint = shiftHints[index] ?? .init()
        hint.recordDrag(from: start, to: end)
        setShiftHint(index: index, hint: hint, asReference: positionReference?.sourceIndex == index)
    }
    func clearPosition(_ index: Int) {
        setShiftHint(index: index, hint: .init(), asReference: false)
    }
    func setLCCEnabled(_ enabled: Bool) {
        lccEnabled = enabled
        changeLCC(automaticallyLocate: enabled)
    }
    func changeLCC(automaticallyLocate: Bool = false) {
        updateLCC(automaticallyLocate ? .locateAndApply : .apply)
    }
    func alignLCC() { updateLCC(.editManually) }
    func solvePosition() {
        guard lccEnabled, positionReference == nil else { return }
        updateLCC(.reviewEstimate)
    }

    private enum LCCAction { case apply, locateAndApply, editManually, reviewEstimate }

    private func updateLCC(_ action: LCCAction) {
        guard registrationMode == .shift else { lccEnabled = false; return }
        guard let current = plan, !busy, alignmentWindow == nil else { return }
        guard current.isRegistered else { lccEnabled = false; return }
        if !lccEnabled && action != .editManually {
            guard current.lccState != nil else { return }
            run { engine, token, _ in try engine.removingLCC(current, cancellation: token) }
            return
        }
        guard let id = UUID(uuidString: selectedLensProfileID), let sensor else {
            error = L10n.tr("fca735eecc8a")
            if current.lccState == nil { lccEnabled = false }
            return
        }
        let pinned = measuredReference?.profileOffset(in: current, sensor: sensor)
        let offset = hasManualLCCPosition ? lccOffset : (pinned ?? lccOffset)
        let shouldLocate = action == .reviewEstimate || (action == .locateAndApply && !hasManualLCCPosition && pinned == nil)
        let crop = cropToLCC, exposure = exposureEV, protect = protectHighlights
        let wb: (Float, Float)? = automaticLCCWB ? nil : (Float(lccTemperature), Float(lccTint))
        let body = cameraBody, orientation = bodyOrientation, hints = resolvedHints
        let cached = lccSession, store = profileStore, previousStatus = status
        cancellation.cancel()
        let token = PanoramaCancellation()
        cancellation = token
        busy = true
        error = nil
        status = shouldLocate ? L10n.tr("6631ec06dcd5") : L10n.tr("299e5b1859ed")
        queue.async { [weak self] in
            let engine = PanoramaEngine()
            let progress: PanoramaEngine.Progress = { message in
                DispatchQueue.main.async {
                    guard let self, self.busy, self.cancellation === token, (try? token.check()) != nil else { return }
                    self.status = message
                }
            }
            do {
                let session: LCCEditingSession
                if let cached, cached.profile.id == id, cached.sensor == sensor { session = cached }
                else {
                    session = try LCCEditingSession(plan: current, profile: store.load(id), sensor: sensor,
                                                    engine: engine, token: token, progress: progress)
                }
                var prepared = current
                prepared.originalPreviewImages = session.preparedPlan.originalPreviewImages
                prepared.lccLinearPreviewImages = session.preparedPlan.lccLinearPreviewImages
                prepared.lccRawPreviews = session.preparedPlan.lccRawPreviews
                prepared.lccFlatPreviews = session.preparedPlan.lccFlatPreviews
                let base = prepared
                var solution: LCCPositionSolution?, locationIssue: String?
                if shouldLocate {
                    do {
                        solution = try LCCPositionSolver.solve(plan: base, fields: session.fields, sensor: sensor,
                            cameraBody: body, bodyOrientation: orientation, shiftHints: hints,
                            cancellation: token, progress: progress)
                    } catch {
                        try token.check()
                        if action == .reviewEstimate { throw error }
                        locationIssue = L10n.tr("2f7403431f62", error.localizedDescription)
                    }
                }
                let resolved = solution?.offsetMM ?? offset, explanation = solution?.explanation
                let render = { (position: CGPoint, cancellation: PanoramaCancellation) throws -> PanoramaPlan in
                    try engine.applyingLCC(base, profile: session.profile, fields: session.fields,
                        offsetMM: position, sensor: sensor, crop: crop, cancellation: cancellation,
                        exposureEV: exposure, protectHighlights: protect, whiteBalanceOverride: wb,
                        cameraBody: body, bodyOrientation: orientation)
                }
                let editing = action == .editManually || action == .reviewEstimate
                let result = editing ? nil : try render(resolved, token)
                let issue = locationIssue
                DispatchQueue.main.async {
                    guard let self, self.cancellation === token else { return }
                    self.busy = false
                    self.status = previousStatus
                    guard (try? token.check()) != nil else { return }
                    self.lccSession = session
                    if let result {
                        self.lccOffset = resolved
                        self.plan = result
                        self.selectLensProfile()
                        if let explanation {
                            self.estimatedReference = self.reference(at: resolved, in: result, sensor: sensor)
                            self.positionExplanation = explanation
                        } else if let issue { self.positionExplanation = issue }
                        self.error = issue
                        self.status = explanation == nil ? L10n.tr("8dc393a05b0d") : L10n.tr("a20a67918b78")
                    } else {
                        self.presentAlignment(plan: base, sensor: sensor, offset: resolved,
                                              explanation: explanation, render: render)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.cancellation === token else { return }
                    self.busy = false
                    self.status = previousStatus
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func presentAlignment(plan: PanoramaPlan, sensor: SensorSize, offset: CGPoint, explanation: String?,
                                  render: @escaping (CGPoint, PanoramaCancellation) throws -> PanoramaPlan) {
        let editor = LCCAlignmentModel(plan: plan, sensor: sensor, offset: offset, explanation: explanation,
                                       renderPreview: render) { [weak self] result in
            guard let self, let state = result.lccState else { return }
            let acceptedEstimate = explanation != nil && state.offsetMM == offset
            self.hasManualLCCPosition = !acceptedEstimate
            self.estimatedReference = acceptedEstimate ? self.reference(at: state.offsetMM, in: result, sensor: sensor) : nil
            self.positionExplanation = acceptedEstimate ? (explanation ?? "") : ""
            self.lccOffset = state.offsetMM
            self.lccEnabled = true
            self.plan = result
            self.status = L10n.tr("b733a8d2ca5b")
        }
        let controller = LCCAlignmentWindowController(model: editor)
        controller.onClose = { [weak self] in self?.alignmentWindow = nil }
        alignmentWindow = controller
        if let window, let sheet = controller.window { window.beginSheet(sheet) }
        else { controller.showWindow(nil) }
    }
    func refreshLCC() {
        lccCount = LCCPairingStore().records().filter { urls.contains($0.scene) }.count
        LCCProfileLibraryModel.shared.refresh()
    }
    func selectLensProfile() {
        guard registrationMode == .shift else {return}
        UserDefaults.standard.set(selectedLensProfileID,forKey:"Photons.panorama.lensProfileID")
        guard var plan else { return }
        let profile=lensProfiles.first { $0.id.uuidString==selectedLensProfileID }
        plan.lensProfileSelections=plan.sources.map { source in
            guard let profile else {return nil}
            var resolvedSensor=source.sensor ?? sensor
            if let s=resolvedSensor, (source.size.height>source.size.width) != (s.height>s.width) {
                resolvedSensor=SensorSize(width:s.height,height:s.width,source:s.source)
            }
            guard let variant=profile.match(camera:source.camera,exifOrientation:source.orientation,sensor:resolvedSensor,cameraBody:cameraBody,bodyOrientation:bodyOrientation) else {return nil}
            return LCCProfileBinding(profile:profile,variant:variant)
        }
        self.plan=plan
    }
    func manageLCC(showProfiles:Bool = false) {
        if showProfiles {
            LCCProfileLibraryWindowController.shared.open(select:UUID(uuidString:selectedLensProfileID))
            return
        }
        let controller = LCCWindowController(urls:urls)
        controller.onClose = { [weak self] in self?.refreshLCC(); self?.lccWindow = nil }
        lccWindow = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    var sensor: SensorSize? {
        var value:SensorSize?
        switch sensorChoice {
        case 0: value=plan?.sources.first?.sensor
        case 1: value=SensorSize(width:43.8,height:32.9,source:L10n.tr("fe1ba1e1b306"))
        case 2: value=SensorSize(width:54,height:40,source:L10n.tr("288f3856c6ea"))
        case 3: value=SensorSize(width:36,height:24,source:L10n.tr("749c9afbfd71"))
        default: value=sensorWidth>0 && sensorHeight>0 && sensorWidth<100 && sensorHeight<100 ? SensorSize(width:sensorWidth,height:sensorHeight,source:L10n.tr("4eafa9e925b3")):nil
        }
        if let source=plan?.sources.first,let s=value,(source.size.height>source.size.width) != (s.height>s.width) {
            value=SensorSize(width:s.height,height:s.width,source:s.source)
        }
        return value
    }
    func chooseMode() {
        guard !busy else {return}
        alignmentWindow?.close();editingPosition=nil
        choosingMode=true;plan=nil;error=nil;status=""
    }
    func prepare(mode:PanoramaRegistrationMode?=nil) {
        guard !busy else {return}
        if let mode {registrationMode=mode}
        choosingMode = false;hasManualLCCPosition=false;lccSession=nil;lccEnabled=false;cropToLCC=false;estimatedReference=nil;lccOffset = .zero;alignmentNeedsUpdate=false
        alignmentWindow?.close();editingPosition=nil
        let mode = registrationMode, hints = registrationMode == .shift ? registrationHints : [:]
        appliedRegistrationHints = hints
        let sensor=registrationMode == .shift ? self.sensor:nil
        plan=nil // A failed retry must not leave an older panorama available for export.
        run { [urls,options] engine,token,progress in
            do {return try engine.analyze(urls:urls,options:options,shiftHints:hints,sensorOverride:sensor,registrationMode:mode,cancellation:token,progress:progress)}
            catch {
                try token.check()
                guard mode == .shift else {throw error}
                return try engine.alignmentDraft(urls:urls,knownPositions:hints.compactMapValues(\.point),sensorOverride:sensor,message:error.localizedDescription,cancellation:token)
            }
        }
    }
    private var previewStatus: PanoramaPreviewStatus {
        plan?.previewStatus(for: options, mode: registrationMode, alignmentChanged: alignmentNeedsUpdate) ?? .needsAlignment
    }
    func refresh() {
        guard !busy, let current = plan, previewStatus == .needsSeamUpdate else { return }
        alignmentWindow?.close()
        run { [options] engine,token,progress in try engine.update(current,options:options,cancellation:token,progress:progress) }
    }
    func changeTone() {
        guard let current = plan, current.isRegistered, !busy, tone.isValid else { return }
        run { _,token,_ in try token.check(); return current }
    }
    private func run(_ operation: @escaping (PanoramaEngine,PanoramaCancellation,@escaping PanoramaEngine.Progress) throws -> PanoramaPlan) {
        cancellation.cancel(); cancellation = PanoramaCancellation()
        let token = cancellation, tone = tone; busy = true; error = nil
        queue.async { [weak self] in
            let outcome = Result {
                let engine = PanoramaEngine()
                var result = try operation(engine,token) { message in DispatchQueue.main.async { self?.status = message } }
                if result.isRegistered && result.tone != tone {
                    result = try engine.applyingTone(result,settings:tone,cancellation:token)
                }
                return result
            }
            DispatchQueue.main.async {
                guard let self, self.cancellation === token else { return }
                self.busy = false
                do {
                    try token.check()
                    let result = try outcome.get()
                    self.plan = result
                    self.selectLensProfile()
                    self.status = result.isRegistered ? L10n.tr("8dc393a05b0d") : L10n.tr("50ab666cb70c")
                } catch {
                    if let plan = self.plan, plan.isRegistered { self.options = plan.options }
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                    self.status = ""
                }
            }
        }
    }
    var canStitch:Bool {
        guard !choosingMode, !busy, let plan, previewStatus == .current, plan.tone == tone else { return false }
        if registrationMode == .perspective {return !lccEnabled && plan.lccState==nil && plan.warps != nil}
        if !lccEnabled {return plan.lccState==nil}
        guard let lcc=plan.lccState else {return false}
        if !automaticLCCWB {guard let wb=lcc.whiteBalance,wb.0==Float(lccTemperature),wb.1==Float(lccTint) else {return false}}
        return lcc.profileID.uuidString==selectedLensProfileID && lcc.offsetMM==lccOffset && (lcc.cropRect != nil)==cropToLCC && lcc.sensor==sensor && lcc.exposureEV==exposureEV && lcc.protectHighlights==protectHighlights && lcc.cameraBody==cameraBody && lcc.bodyOrientation==bodyOrientation
    }
    func exportManifest(for plan:PanoramaPlan)->PanoramaManifest {
        if plan.registrationMode == .perspective {return PanoramaManifest(plan:plan)}
        let profile=lensProfiles.first {$0.id.uuidString==selectedLensProfileID}
        return PanoramaManifest(plan:plan,profileID:profile?.id,profileName:profile?.name,
            offsetMM:hasManualLCCPosition ? lccOffset : (sensor.flatMap { measuredReference?.profileOffset(in:plan,sensor:$0) } ?? (estimatedReference != nil ? lccOffset : nil)),
            sensor:sensor,bodyOrientation:bodyOrientation,cameraBody:cameraBody)
    }
    func stitch() {
        guard let plan, let window, canStitch else { return }
        let manifest=exportManifest(for:plan)
        let controller=PanoramaExportController(plan:plan,manifest:manifest)
        controller.onExported=onExported
        controller.onQueued={ [weak self] in self?.exportWindow=nil;self?.window?.close() }
        exportWindow=controller
        controller.present(in:window)
    }
}

private struct PanoramaWorkspace: View {
    @ObservedObject var model: PanoramaWindowModel
    @ObservedObject private var profileLibrary = LCCProfileLibraryModel.shared
    var body: some View {
        Group {
            if model.choosingMode { modeSelection }
            else { workspace }
        }
        .onReceive(profileLibrary.$profiles) { profiles in
            model.lensProfiles=profiles;model.selectLensProfile()
        }
        .onReceive(profileLibrary.$error) { error in
            model.profileStatus=error ?? L10n.tr("5af8232321e0")
        }
        .alert(L10n.tr("8b92765d86d0"),isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) {
            Button(L10n.tr("f867f3417859"),role:.cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented:Binding(get:{model.editingPosition != nil},set:{if !$0 {model.editingPosition=nil}})) {
            if let index=model.editingPosition,let plan=model.plan,let sensor=model.sensor {
                let suggestion = model.overviewReference?.position(of:index,in:plan,sensor:sensor) ?? .zero
                PanoramaPositionEntry(filename: plan.sources[index].url.lastPathComponent, hint: model.shiftHints[index] ?? .init(),
                    suggestion: suggestion, body: model.cameraBody, orientation: model.bodyOrientation, calibration: model.endStopCalibration,
                    isReference: model.positionReference?.sourceIndex == index, hasPosition: model.shiftHints[index] != nil) { hint, pinned in
                    model.editingPosition=nil;model.setShiftHint(index:index,hint:hint,asReference:pinned)
                } onClear: {model.editingPosition=nil;model.clearPosition(index)} onCancel: {model.editingPosition=nil}
            }
        }
    }
    private var modeSelection: some View {
        VStack(alignment:.leading,spacing:24) {
            Text(L10n.tr("e7e00c84ee53")).font(.largeTitle.bold())
            Text(L10n.tr("18a20c5ab680" , String(describing: (model.urls.count)))).foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:12) {
                Label { Text(L10n.tr("e0a7acc067fd")) } icon: { PanoramaModeIcon() }.font(.title2.bold())
                Text(L10n.tr("f6ec5765c5b6"))
                Button(L10n.tr("0f638e919d73")) { model.prepare(mode:.shift) }.buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("panorama.mode.shift")
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:8) {
                Label { Text(L10n.tr("713e40499206")) } icon: { PanoramaModeIcon(perspective:true) }.font(.title2)
                Text(L10n.tr("panorama.perspectiveDescription")).foregroundStyle(.secondary)
                Button(L10n.tr("0f638e919d73")) { model.prepare(mode:.perspective) }.buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("panorama.mode.perspective")
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(.quinary,in:RoundedRectangle(cornerRadius:14))
            Text(L10n.tr("62fd2de26931"))
                .font(.callout).foregroundStyle(.secondary)
        }.padding(48).frame(maxWidth:720).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var workspace: some View {
        VStack(spacing:0) {
            HStack(spacing:0) {
                VStack(spacing:0) {
                    ZStack {
                        Color(nsColor:.underPageBackgroundColor)
                        if let plan = model.plan, let cg = plan.preview {
                            PanoramaHDRPreview(image: cg, outputPixels: plan.outputSize)
                                .padding(18)
                        } else {
                            VStack(spacing:14) {
                                Image(systemName:"panorama").font(.system(size:52)).foregroundStyle(.secondary)
                                Text(model.busy ? L10n.tr("248c5f929e45") : L10n.tr("e885a990b960"))
                                if !model.busy { Button(L10n.tr("03b1a13cf2c0")) { model.prepare() } }
                            }
                        }
                        if model.busy { VStack { Spacer(); ProgressView(model.status).padding(16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) }.padding(20) }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                    if model.plan?.isRegistered == true { brightnessControls }
                }
                Divider()
                ScrollView { inspector.padding(20) }.frame(width:340)
            }
            Divider()
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text(model.status).lineLimit(1)
                    if let plan = model.plan { Text(L10n.tr("f423e12e53c9" , String(describing: (Int(plan.outputSize.width))), String(describing: (Int(plan.outputSize.height))), String(format: "%.1f", plan.outputSize.width*plan.outputSize.height/1_000_000), String(describing: (plan.sources.count))))
                        .font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.busy { Button(L10n.tr("2cd0f3be8738")) { model.cancel() } }
                Button(L10n.tr("630ca11bfbde")) { model.stitch() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStitch)
            }.padding(16)
        }
    }
    private var brightnessControls: some View {
        let resetExposure = { model.tone.exposureEV = PanoramaToneSettings.panoramaDefault.exposureEV; model.changeTone() }
        let resetHighlights = { model.tone.highlightHeadroom = PanoramaToneSettings.panoramaDefault.highlightHeadroom; model.changeTone() }
        return VStack(alignment:.leading,spacing:6) {
            Divider()
            HStack(spacing:20) {
                VStack {
                    HStack { Text(L10n.tr("4626a2810ff9")).modifier(ResetOnDoubleClick(action: resetExposure)); Spacer(); Text(String(format:"%+.2f EV",model.tone.exposureEV)).monospacedDigit() }
                    AdjustmentSlider(value:$model.tone.exposureEV,in:-4...4,step:0.05,onReset:resetExposure,onEditingChanged:{ if !$0 {model.changeTone()} })
                }
                VStack {
                    HStack { Text(L10n.tr("panorama.tone.highlights")).modifier(ResetOnDoubleClick(action: resetHighlights)); Spacer(); Text(String(format:"%.1f",log2(model.tone.highlightHeadroom ?? 4))).monospacedDigit() }
                    AdjustmentSlider(value:Binding(get:{log2(model.tone.highlightHeadroom ?? 4)},set:{model.tone.highlightHeadroom=pow(2,$0)}),in:0...4,step:0.1,onReset:resetHighlights,onEditingChanged:{if !$0 {model.changeTone()}})
                }
                Button(L10n.tr("panorama.tone.reset")) {model.tone = .panoramaDefault;model.changeTone()}
                    .disabled(model.tone == .panoramaDefault)
            }
            Text(L10n.tr("panorama.tone.hint")).font(.caption).foregroundStyle(.secondary)
        }.padding(12).disabled(model.busy)
    }
    private func resetSeamSoftness() {
        let original = PanoramaOptions().seamSoftness
        guard model.options.seamSoftness != original else { return }
        model.options.seamSoftness = original
        model.refresh()
    }

    private var inspector: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.tr(model.registrationMode == .shift ? "e0a7acc067fd":"713e40499206")).font(.title2.bold())
            Button(L10n.tr("panorama.changeMode")) {model.chooseMode()}
                .accessibilityIdentifier("panorama.changeMode")
            if model.registrationMode == .shift {shiftControls}
            else {
                Text(L10n.tr("panorama.perspectiveLimits")).font(.callout).foregroundStyle(.secondary)
                Text(L10n.tr("panorama.perspectiveLCCNotice")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(L10n.tr("71e8dddcf62b")).font(.headline)
            Toggle(L10n.tr("panorama.deghost.label"),isOn:$model.options.avoidMotion).toggleStyle(.checkbox)
                .accessibilityIdentifier("panorama-deghost")
                .onChange(of:model.options.avoidMotion) { _,_ in model.refresh() }
            Text(L10n.tr("panorama.deghost.hint")).font(.caption).foregroundStyle(.secondary)
            Toggle(L10n.tr("f332d17f7e09"),isOn:$model.options.matchExposure).onChange(of:model.options.matchExposure) { _,_ in model.refresh() }
            Text(L10n.tr("802a18c71f09")).font(.callout)
                .modifier(ResetOnDoubleClick(action: resetSeamSoftness))
            AdjustmentSlider(value: $model.options.seamSoftness, in: 0...12, step: 1,
                             onReset: resetSeamSoftness, onEditingChanged: { if !$0 { model.refresh() } })
            Picker(L10n.tr("f55043412c64"),selection:$model.options.preferredSource) {
                Text(L10n.tr("db9773faa309")).tag(-1)
                ForEach(Array(model.urls.enumerated()),id:\.offset) { i,url in Text(url.lastPathComponent).tag(i) }
            }.onChange(of:model.options.preferredSource) { _,_ in model.refresh() }
            Text(L10n.tr("95875297cbcd")).font(.caption).foregroundStyle(.secondary)
            if model.registrationMode == .shift {
                Divider()
                Button(L10n.tr("9e4be2d889be")) { model.manageLCC() }
                Text(L10n.tr("26747f634b19" , String(describing: (model.lccCount)), String(describing: (model.urls.count)))).font(.caption).foregroundStyle(.secondary)
            }

        }.disabled(model.busy)
        .onChange(of:model.sensorChoice) {_,_ in model.selectLensProfile();if model.lccEnabled {model.changeLCC()}}
        .onChange(of:model.sensorWidth) {_,_ in model.selectLensProfile();if model.lccEnabled {model.changeLCC()}}
        .onChange(of:model.sensorHeight) {_,_ in model.selectLensProfile();if model.lccEnabled {model.changeLCC()}}
    }
    @ViewBuilder private var shiftControls:some View {
            VStack(alignment:.leading,spacing:6) {
                Text(L10n.tr("dcd3ee9cec9b")).font(.headline)
                CameraBodyPicker(selection:Binding(get:{model.cameraBody},set:{model.setBody($0)})).labelsHidden()
                PanoramaBodyOrientationPicker(cameraBody:model.cameraBody,selection:Binding(get:{model.bodyOrientation},set:{model.setBodyOrientation($0)}))
                Text(model.cameraBody.travel(at:model.bodyOrientation).summary).font(.caption).foregroundStyle(.secondary)
            }
            if let plan = model.plan {
                PanoramaPositionOverview(plan: plan, sensor: model.sensor, reference: model.overviewReference,
                    cameraBody: model.cameraBody, bodyOrientation: model.bodyOrientation,
                    hints: model.shiftHints, resolved: model.resolvedHints, onMove: model.moveFrame) { model.editingPosition = $0 }
                if plan.isRegistered && model.shiftHints.isEmpty {
                    Text(model.overviewReference != nil ? L10n.tr("a1d86877af02") : L10n.tr("92edb20a3dbc"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !plan.isRegistered {Text(L10n.tr("de949bd06103")).font(.caption).foregroundStyle(.orange)}
                Text(L10n.tr("5e76d67d4617" , String(describing: (model.shiftHints.count)))).font(.caption).foregroundStyle(.secondary)
                if model.shiftHints.count>1 || model.alignmentNeedsUpdate || !plan.isRegistered {
                    Button(L10n.tr("03b1a13cf2c0")) {model.prepare()}
                    if model.alignmentNeedsUpdate {Text(L10n.tr("a41d4452a74e")).font(.caption).foregroundStyle(.orange)}
                }
            }
            Picker(L10n.tr("a4f7cbe44e92"),selection:$model.sensorChoice) {
                Text(L10n.tr("97f973377efe")).tag(0); Text("44 × 33 · 43.8 × 32.9 mm").tag(1)
                Text("54 × 40 mm").tag(2); Text("135 · 36 × 24 mm").tag(3); Text(L10n.tr("8a2e28474a49")).tag(4)
            }
            if model.sensorChoice == 4 {
                HStack { TextField(L10n.tr("345ff469e07d"),value:$model.sensorWidth,format:.number); Text("×"); TextField(L10n.tr("b8da5e89518e"),value:$model.sensorHeight,format:.number) }.textFieldStyle(.roundedBorder)
            }
            if let sensor = model.sensor {
                Text("\(sensor.width,specifier:"%.2f") × \(sensor.height,specifier:"%.2f") mm\n\(sensor.source)").font(.caption).foregroundStyle(.secondary)
            } else { Text(L10n.tr("0edf8c27def3")).font(.caption).foregroundStyle(.orange) }
            Divider()
            Text(L10n.tr("7702014ae81a")).font(.headline)
            if model.hasManualLCCPosition {
                Text(L10n.tr("panorama.lcc.manualPosition", String(format: "%+.2f", model.lccOffset.x),
                             String(format: "%+.2f", model.lccOffset.y))).font(.caption)
                if model.positionReference != nil {
                    Button(L10n.tr("panorama.lcc.useReference")) { model.usePositionReference() }
                }
            } else {
                Text(model.positionReference == nil ? (model.plan?.optical.explanation ?? L10n.tr("9f661eaa4c1a")) : L10n.tr("93fa020baa18")).font(.caption).foregroundStyle(.secondary)
                if model.positionReference == nil,let plan = model.plan, let center = plan.optical.center, let sensor = model.sensor {
                    Text(L10n.tr("73281fd9d6f5" , String(format: "%.1f", (center.x-plan.origins[0].x-plan.sources[0].size.width/2)*sensor.width/plan.sources[0].size.width), String(format: "%.1f", (center.y-plan.origins[0].y-plan.sources[0].size.height/2)*sensor.height/plan.sources[0].size.height)))
                        .font(.caption)
                }
                if model.positionReference != nil, let reference=model.overviewReference,let plan=model.plan {
                    Text(L10n.tr("a6805c058eaa" , String(describing: (plan.sources[reference.sourceIndex].url.lastPathComponent)), String(format: "%+.1f", reference.positionMM.x), String(format: "%+.1f", reference.positionMM.y))).font(.caption)
                    Button(L10n.tr("47966d105fad")) {model.positionReference=nil;model.estimatedReference=nil;model.lccOffset = .zero;model.changeLCC(automaticallyLocate:true)}
                } else if model.estimatedReference != nil {
                    Text(model.positionExplanation).font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker(L10n.tr("185ffacaf4ad"),selection:$model.selectedLensProfileID) {
                Text(L10n.tr("d03dcdd057a2")).tag("")
                ForEach(model.lensProfiles) { Text($0.name).tag($0.id.uuidString) }
            }.onChange(of:model.selectedLensProfileID) { _,_ in model.selectLensProfile(); model.updateHintStatus(); model.changeLCC(automaticallyLocate:true) }
            Text(model.profileStatus).font(.caption).foregroundStyle(.secondary)
            if let plan=model.plan, !model.selectedLensProfileID.isEmpty {
                ForEach(plan.sources.indices,id:\.self) { i in
                    HStack(alignment:.top) {
                        Text(plan.sources[i].url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if plan.lensProfileSelections.indices.contains(i),let binding=plan.lensProfileSelections[i] {
                            Text(L10n.tr("f7485cc751f2" , String(describing: (binding.orientation.title)), String(describing: (binding.captureCount)))).foregroundStyle(.secondary)
                        } else {Text(L10n.tr("10f0730bd9d6")).foregroundStyle(.orange)}
                    }.font(.caption)
                }
            }
            Button(L10n.tr("23615da9ada4")) {model.manageLCC(showProfiles:true)}
            Toggle(L10n.tr("945ac5c3da15"),isOn: Binding(get: { model.lccEnabled }, set: model.setLCCEnabled)).toggleStyle(.checkbox)
                .disabled(model.plan?.isRegistered != true)
            Button(L10n.tr("693a0e217822")) { model.alignLCC() }
                .disabled(model.plan?.isRegistered != true || model.sensor == nil || model.selectedLensProfileID.isEmpty)
                .accessibilityIdentifier("panorama.lcc.manual")
            if model.lccEnabled {
                if let warning=model.plan?.lccState?.warning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                    Toggle(L10n.tr("61635e357c96"),isOn:$model.cropToLCC).toggleStyle(.checkbox)
                        .disabled(model.plan?.lccState?.suggestedCropRect == nil)
                        .onChange(of:model.cropToLCC) {_,_ in model.changeLCC()}
                } else if model.cropToLCC {
                    Toggle(L10n.tr("61635e357c96"),isOn:$model.cropToLCC).toggleStyle(.checkbox)
                        .onChange(of:model.cropToLCC) {_,_ in model.changeLCC()}
                }
                Button(L10n.tr("45d14f0c4f3d")) {model.solvePosition()}.disabled(model.positionReference != nil)
                Text(L10n.tr("3b0da2de91ba")).font(.caption)
                Toggle(L10n.tr("fa9bce35de33"),isOn:$model.automaticLCCWB).toggleStyle(.checkbox)
                    .onChange(of:model.automaticLCCWB) {_,value in
                        if !value,let wb=model.plan?.lccState?.whiteBalance {model.lccTemperature=Double(wb.0);model.lccTint=Double(wb.1)}
                        model.changeLCC()
                    }
                if let wb=model.plan?.lccState?.whiteBalance {
                    Text(L10n.tr("de9d8ad34ef8" , String(describing: (model.plan?.lccState?.whiteBalanceSource ?? "")), String(describing: (Int(wb.0.rounded()))), String(format: "%.1f", wb.1))).font(.caption).foregroundStyle(.secondary)
                }
                if !model.automaticLCCWB {
                    HStack {
                        Text(L10n.tr("84ac609620e5"));TextField("K",value:$model.lccTemperature,format:.number.precision(.fractionLength(0))).onSubmit {model.changeLCC()}
                        Text(L10n.tr("5bddf6a1c0f5"));TextField("Tint",value:$model.lccTint,format:.number.precision(.fractionLength(1))).onSubmit {model.changeLCC()}
                    }.textFieldStyle(.roundedBorder)
                    Button(L10n.tr("7d5e9c09c086")) {model.changeLCC()}
                }
                Text(model.hasManualLCCPosition ? L10n.tr("panorama.lcc.manualActive") : L10n.tr(model.positionReference == nil ? "571a6cd6f748" : "531e654e1a1e")).font(.caption).foregroundStyle(.secondary)
            }
    }
}

private struct PanoramaPositionEntry:View {
    let filename:String
    let hasPosition:Bool
    let onSave:(PanoramaShiftHint,Bool)->Void
    let onClear:()->Void
    let onCancel:()->Void
    let suggestion: CGPoint
    let bodyType: PanoramaCameraBody
    let orientation: PanoramaBodyOrientation
    let calibration: LCCEndStopCalibration?
    @State private var hint: PanoramaShiftHint
    @State private var isReference: Bool
    init(filename:String, hint: PanoramaShiftHint, suggestion: CGPoint, body: PanoramaCameraBody, orientation: PanoramaBodyOrientation,
         calibration: LCCEndStopCalibration?, isReference:Bool, hasPosition:Bool, onSave:@escaping(PanoramaShiftHint,Bool)->Void,
         onClear:@escaping()->Void,onCancel:@escaping()->Void) {
        self.filename=filename;self.hasPosition=hasPosition;self.onSave=onSave;self.onClear=onClear;self.onCancel=onCancel
        self.suggestion=suggestion;bodyType=body;self.orientation=orientation;self.calibration=calibration
        _hint=State(initialValue:hint);_isReference=State(initialValue:isReference)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.tr("26de880334ca")).font(.title2.bold())
            Text(filename).font(.headline)
            Text(L10n.tr("5851c578611d")).font(.callout)
            PanoramaShiftHintEditor(hint:$hint,suggestion:suggestion,body:bodyType,orientation:orientation,calibration:calibration)
            Text(L10n.tr("panorama.shift.guidance")).font(.caption).foregroundStyle(.secondary)
            let complete = hint.resolved(body:bodyType,orientation:orientation,calibration:calibration).point != nil
            if complete { Toggle(L10n.tr("13097721eadb"),isOn:$isReference).toggleStyle(.checkbox) }
            HStack {
                Button(L10n.tr("44acfaf249fe"),action:onClear).disabled(!hasPosition)
                Spacer()
                Button(L10n.tr("2cd0f3be8738"),action:onCancel)
                Button(L10n.tr("d977ab79b013")) { onSave(hint, complete && isReference) }
                    .buttonStyle(.borderedProminent).disabled(hint == PanoramaShiftHint() && !hasPosition)
            }
        }.padding(24).frame(width:420).textFieldStyle(.roundedBorder)
    }
}

struct PanoramaPositionOverview: View {
    let plan: PanoramaPlan
    let sensor: SensorSize?
    let reference: PanoramaPositionReference?
    let cameraBody: PanoramaCameraBody
    let bodyOrientation: PanoramaBodyOrientation
    let hints: [Int: PanoramaShiftHint]
    let resolved: [Int: PanoramaShiftPosition]
    var onMove: ((Int, CGPoint, CGPoint) -> Void)?
    let onSelect: (Int) -> Void

    var frames: [CapturePositionDiagram.Frame] {
        plan.sources.indices.map { i in
            let rect = plan.sensorRect(i)
            let size = sensor ?? SensorSize(width: rect.width, height: rect.height, source: "pixels")
            let center = reference.flatMap { ref in sensor.map { ref.position(of: i, in: plan, sensor: $0) } }
                ?? CGPoint(x: (rect.midX - plan.size.width / 2) * size.width / rect.width,
                           y: (plan.size.height / 2 - rect.midY) * size.height / rect.height)
            let reading = resolved[i] ?? .init()
            // Unknown axes retain their image/draft layout. Pixel coordinates cannot be mixed with millimetres.
            let shown = sensor == nil ? center : CGPoint(x: reading.x ?? center.x, y: reading.y ?? center.y)
            let hint = hints[i] ?? .init()
            let caption = [reading.x.map { axisText(hint.x, value: $0, horizontal: true) },
                           reading.y.map { axisText(hint.y, value: $0, horizontal: false) }]
                .compactMap { $0 }.joined(separator: " · ")
            return .init(name: plan.sources[i].url.lastPathComponent, center: shown, sensor: size,
                         reading: caption.isEmpty ? nil : caption)
        }
    }

    private func axisText(_ hint: PanoramaAxisHint, value: Double?, horizontal: Bool) -> String {
        let axis = horizontal ? "X" : "Y"
        guard let value else { return "\(axis) ?" }
        let name: String
        switch hint {
        case .negativeMaximum: name = L10n.tr(horizontal ? "panorama.shift.leftMax" : "panorama.shift.downMax")
        case .positiveMaximum: name = L10n.tr(horizontal ? "panorama.shift.rightMax" : "panorama.shift.upMax")
        default: name = axis
        }
        return String(format: "%@ %+.1f", name, value)
    }

    func readingText(_ i: Int) -> String {
        let hint = hints[i] ?? .init(), value = resolved[i] ?? .init()
        return [axisText(hint.x, value: value.x, horizontal: true),
                axisText(hint.y, value: value.y, horizontal: false)].joined(separator: " · ")
    }

    var body: some View {
        let frames = frames
        let numbered = !hints.isEmpty || !plan.isRegistered
        VStack(alignment: .leading, spacing: 4) {
            CapturePositionDiagram(frames: frames, cameraBody: cameraBody, orientation: bodyOrientation,
                absolute: reference != nil, selected: reference?.sourceIndex, showsTravel: sensor != nil,
                numbered: numbered, anchoredX: sensor != nil && resolved.values.contains { $0.x != nil },
                anchoredY: sensor != nil && resolved.values.contains { $0.y != nil },
                onMove: sensor == nil ? nil : onMove, onSelect: onSelect)
                .frame(height: 200).background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            if sensor != nil && onMove != nil {
                Text(L10n.tr("panorama.shift.dragFrame")).font(.caption).foregroundStyle(.secondary)
            }
            if numbered {
                Text(L10n.tr("panorama.shift.diagramReadings")).font(.caption).foregroundStyle(.secondary)
                ForEach(frames.indices, id: \.self) { i in
                    Button { onSelect(i) } label: {
                        HStack {
                            Text(String(i + 1)).fontWeight(.bold).foregroundStyle(CapturePositionDiagram.color(i))
                            Text(frames[i].name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(readingText(i)).monospacedDigit()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.caption)
                }
            }
        }
    }
}
