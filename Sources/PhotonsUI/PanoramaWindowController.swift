import PhotonsLocalization
import AppKit
import PhotonsFileAccess
import SwiftUI
import UniformTypeIdentifiers
import PhotonsPanorama

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
private final class PanoramaWindowModel: ObservableObject {
    let urls: [URL]
    private let sourceAccess: [FileAccess]
    weak var window: NSWindow?
    @Published var choosingMode = true
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var plan: PanoramaPlan?
    @Published var options = PanoramaOptions()
    var onExported: (URL,@escaping(String?)->Void)->Void = {_,done in done(nil)}
    @Published var cameraBody:PanoramaCameraBody = .alpa12Max
    @Published var bodyOrientation:PanoramaBodyOrientation = .degrees0
    @Published var sensorChoice = 0
    @Published var sensorWidth = 43.8
    @Published var sensorHeight = 32.9
    @Published var positionReference:PanoramaPositionReference?
    @Published var knownPositions:[Int:CGPoint]=[:]
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
    @Published var lccOffset=CGPoint.zero
    @Published var exposureEV=0.0
    @Published var automaticLCCWB=true
    @Published var lccTemperature=5500.0
    @Published var lccTint=0.0
    @Published var protectHighlights=true
    private var lccSession:LCCEditingSession?
    private var alignmentWindow:LCCAlignmentWindowController?
    private var lccWindow: LCCWindowController?
    private var exportWindow: PanoramaExportController?
    private var cancellation = PanoramaCancellation()
    private let queue = DispatchQueue(label:"Photons.panorama",qos:.userInitiated)
    init(urls: [URL]) {
        sourceAccess = urls.map { FileAccessStore.shared.access(to: $0) }
        self.urls = sourceAccess.map(\.url); refreshLCC()
    }
    func cancel() { cancellation.cancel(); exportWindow?.dismiss() }
    func setBody(_ body:PanoramaCameraBody) {
        cameraBody=body;bodyOrientation=body.canonicalOrientation(bodyOrientation);bodyPlacementChanged()
    }
    func setBodyOrientation(_ orientation:PanoramaBodyOrientation) {
        guard orientation != bodyOrientation else {return}
        bodyOrientation=orientation;bodyPlacementChanged()
    }
    private func bodyPlacementChanged() {
        alignmentWindow?.close();selectLensProfile()
        if positionReference==nil {estimatedReference=nil;positionExplanation="";lccOffset = .zero}
        if lccEnabled {changeLCC(automaticallyLocate:true)}
    }
    var overviewReference:PanoramaPositionReference? {positionReference ?? estimatedReference}
    func setPositionReference(index:Int,x:Double,y:Double,asReference:Bool) {
        guard x.isFinite,y.isFinite,abs(x)<=150,abs(y)<=150 else {error=L10n.tr("2dce53ce7a65");return}
        alignmentWindow?.close()
        knownPositions[index]=CGPoint(x:x,y:y)
        if asReference {positionReference=PanoramaPositionReference(sourceIndex:index,positionMM:CGPoint(x:x,y:y));estimatedReference=nil}
        else if positionReference?.sourceIndex==index {positionReference=nil;estimatedReference=nil;lccOffset = .zero}
        alignmentNeedsUpdate=knownPositions.count>1
        changeLCC()
    }
    func clearPosition(_ index:Int) {
        knownPositions.removeValue(forKey:index)
        if positionReference?.sourceIndex==index {positionReference=nil;estimatedReference=nil;lccOffset = .zero;changeLCC()}
        alignmentNeedsUpdate=knownPositions.count>1
    }
    func changeLCC(automaticallyLocate:Bool=false) {
        guard let current=plan,!busy else {return}
        guard current.isRegistered else {lccEnabled=false;return}
        if let reference=positionReference,let sensor {lccOffset=reference.profileOffset(in:current,sensor:sensor)}
        if !lccEnabled {
            run {engine,token,_ in try engine.removingLCC(current,cancellation:token)};return
        }
        guard let id=UUID(uuidString:selectedLensProfileID),let sensor else {error=L10n.tr("fca735eecc8a");lccEnabled=false;return}
        let cached=lccSession,offset=lccOffset,crop=cropToLCC,exposure=exposureEV,protect=protectHighlights
        let wb:(Float,Float)?=automaticLCCWB ? nil:(Float(lccTemperature),Float(lccTint))
        let shouldLocate=automaticallyLocate && positionReference==nil
        let body=cameraBody,orientation=bodyOrientation
        cancellation.cancel();cancellation=PanoramaCancellation();let token=cancellation
        busy=true;error=nil;status=shouldLocate ? L10n.tr("6631ec06dcd5"):L10n.tr("299e5b1859ed")
        queue.async { [weak self] in
            let engine=PanoramaEngine()
            let progress:PanoramaEngine.Progress={message in
                DispatchQueue.main.async {guard (try? token.check()) != nil else {return};self?.status=message}
            }
            do {
                let session:LCCEditingSession
                if let cached,cached.profile.id==id,cached.sensor==sensor {session=cached}
                else {session=try LCCEditingSession(plan:current,profileID:id,sensor:sensor,engine:engine,token:token,progress:progress)}
                var prepared=current
                prepared.originalPreviewImages=session.preparedPlan.originalPreviewImages
                prepared.lccLinearPreviewImages=session.preparedPlan.lccLinearPreviewImages
                prepared.lccRawPreviews=session.preparedPlan.lccRawPreviews
                prepared.lccFlatPreviews=session.preparedPlan.lccFlatPreviews
                var solution:LCCPositionSolution?,locationIssue:String?
                if shouldLocate {
                    do {solution=try LCCPositionSolver.solve(plan:prepared,fields:session.fields,sensor:sensor,cameraBody:body,bodyOrientation:orientation,cancellation:token,progress:progress)}
                    catch {
                        try token.check()
                        // Keep a usable calibrated preview so a partial profile can still be
                        // aligned manually. Never report a failed estimate as an applied solution.
                        locationIssue=L10n.tr("2f7403431f62" , String(describing: (error.localizedDescription)))
                    }
                }
                let resolvedOffset=solution?.offsetMM ?? offset
                let result=try engine.applyingLCC(prepared,profile:session.profile,fields:session.fields,offsetMM:resolvedOffset,sensor:sensor,crop:crop,cancellation:token,
                    exposureEV:exposure,protectHighlights:protect,whiteBalanceOverride:wb,cameraBody:body,bodyOrientation:orientation)
                try token.check()
                DispatchQueue.main.async {
                    guard let self else {return}
                    guard (try? token.check()) != nil else {self.busy=false;self.status="";return}
                    self.lccSession=session;self.plan=result;self.selectLensProfile()
                    if let solution {
                        self.lccOffset=solution.offsetMM
                        let r=result.sourceRect(0)
                        self.estimatedReference=PanoramaPositionReference(sourceIndex:0,positionMM:CGPoint(
                            x:(r.midX-result.size.width/2)*sensor.width/r.width-solution.offsetMM.x,
                            y:(result.size.height/2-r.midY)*sensor.height/r.height-solution.offsetMM.y))
                        self.positionExplanation=solution.explanation
                    } else if let locationIssue {self.positionExplanation=locationIssue}
                    self.busy=false;self.error=locationIssue
                    self.status=solution != nil ? L10n.tr("a20a67918b78"):L10n.tr("8dc393a05b0d")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.busy=false;self?.status=""
                    if !(error is CancellationError) {self?.error=error.localizedDescription}
                }
            }
        }
    }

    func alignLCC(initialOffset:CGPoint?=nil,explanation:String?=nil,proposal:PanoramaPlan?=nil) {
        guard let plan,let session=lccSession,lccEnabled,!busy,positionReference==nil else {return}
        if let alignmentWindow {alignmentWindow.showWindow(nil);return}
        let c=LCCAlignmentWindowController(plan:proposal ?? plan,session:session,offset:initialOffset ?? lccOffset,crop:cropToLCC,explanation:explanation) { [weak self] result,offset in
            guard self?.positionReference==nil else {return}
            self?.plan=result;self?.lccOffset=offset;self?.status=L10n.tr("b733a8d2ca5b")
            let r=result.sourceRect(0)
            self?.estimatedReference=PanoramaPositionReference(sourceIndex:0,positionMM:CGPoint(
                x:(r.midX-result.size.width/2)*session.sensor.width/r.width-offset.x,
                y:(result.size.height/2-r.midY)*session.sensor.height/r.height-offset.y))
            self?.positionExplanation=explanation ?? L10n.tr("1eaba71129bf")
        }
        c.onClose={ [weak self] in self?.alignmentWindow=nil };alignmentWindow=c;c.showWindow(nil);c.window?.makeKeyAndOrderFront(nil)
    }
    func solvePosition() {
        guard let current=plan,let session=lccSession,lccEnabled,!busy,positionReference==nil else {return}
        cancellation.cancel();cancellation=PanoramaCancellation();let token=cancellation
        busy=true;error=nil;status=L10n.tr("3e9efb0180ff")
        let amount=exposureEV,protect=protectHighlights
        let body=cameraBody,orientation=bodyOrientation
        let wb:(Float,Float)?=automaticLCCWB ? nil:(Float(lccTemperature),Float(lccTint))
        queue.async { [weak self] in
            do {
                var prepared=current
                prepared.lccLinearPreviewImages=session.preparedPlan.lccLinearPreviewImages
                prepared.lccRawPreviews=session.preparedPlan.lccRawPreviews
                prepared.lccFlatPreviews=session.preparedPlan.lccFlatPreviews
                let solution=try LCCPositionSolver.solve(plan:prepared,fields:session.fields,sensor:session.sensor,cameraBody:body,bodyOrientation:orientation,cancellation:token) {message in
                    DispatchQueue.main.async {self?.status=message}
                }
                let proposal=try PanoramaEngine().applyingLCC(prepared,profile:session.profile,fields:session.fields,offsetMM:solution.offsetMM,
                    sensor:session.sensor,crop:false,cancellation:token,exposureEV:amount,protectHighlights:protect,whiteBalanceOverride:wb,cameraBody:body,bodyOrientation:orientation)
                try token.check()
                DispatchQueue.main.async {
                    guard let self,(try? token.check()) != nil else {return}
                    self.busy=false;self.status=L10n.tr("a005705ea84c")
                    self.alignLCC(initialOffset:solution.offsetMM,explanation:solution.explanation,proposal:proposal)
                }
            } catch {DispatchQueue.main.async {self?.busy=false;self?.status="";if !(error is CancellationError) {self?.error=error.localizedDescription}}}
        }
    }
    func refreshLCC() {
        lccCount = LCCPairingStore().records().filter { urls.contains($0.scene) }.count
        queue.async { [weak self] in
            do {
                let store=LCCProfileStore();try store.installBundledProfile();let catalog=store.catalog()
                DispatchQueue.main.async {
                    self?.lensProfiles=catalog.profiles
                    self?.profileStatus=catalog.issues.isEmpty ? L10n.tr("5af8232321e0") : catalog.issues.joined(separator:"\n")
                    self?.selectLensProfile()
                }
            } catch { DispatchQueue.main.async { self?.profileStatus=error.localizedDescription } }
        }
    }
    func selectLensProfile() {
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
        let controller = LCCWindowController(urls:urls,showProfiles:showProfiles)
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
    func prepare() {
        choosingMode = false;lccSession=nil;lccEnabled=false;cropToLCC=false;estimatedReference=nil;lccOffset = .zero;alignmentNeedsUpdate=false
        let positions=knownPositions,sensor=self.sensor
        run { [urls,options] engine,token,progress in
            do {return try engine.analyze(urls:urls,options:options,knownPositions:positions,sensorOverride:sensor,cancellation:token,progress:progress)}
            catch {
                try token.check()
                return try engine.alignmentDraft(urls:urls,knownPositions:positions,sensorOverride:sensor,message:error.localizedDescription,cancellation:token)
            }
        }
    }
    func refresh() {
        guard let current = plan, current.isRegistered,!busy else { return }
        run { [options] engine,token,progress in try engine.update(current,options:options,cancellation:token,progress:progress) }
    }
    private func run(_ operation: @escaping (PanoramaEngine,PanoramaCancellation,@escaping PanoramaEngine.Progress) throws -> PanoramaPlan) {
        cancellation.cancel(); cancellation = PanoramaCancellation()
        let token = cancellation; busy = true; error = nil
        queue.async { [weak self] in
            do {
                let result = try operation(PanoramaEngine(),token) { message in DispatchQueue.main.async { self?.status = message } }
                try token.check()
                DispatchQueue.main.async { guard (try? token.check()) != nil else {self?.busy=false;return}
                    self?.plan = result; self?.selectLensProfile(); self?.busy = false
                    self?.status = result.isRegistered ? L10n.tr("8dc393a05b0d"):L10n.tr("50ab666cb70c") }
            } catch {
                DispatchQueue.main.async { self?.busy = false; if !(error is CancellationError) { self?.error = error.localizedDescription }; self?.status = "" }
            }
        }
    }
    var canStitch:Bool {
        guard !busy,!alignmentNeedsUpdate,let plan,plan.isRegistered else {return false}
        if !lccEnabled {return plan.lccState==nil}
        guard let lcc=plan.lccState else {return false}
        if !automaticLCCWB {guard let wb=lcc.whiteBalance,wb.0==Float(lccTemperature),wb.1==Float(lccTint) else {return false}}
        return lcc.profileID.uuidString==selectedLensProfileID && lcc.offsetMM==lccOffset && (lcc.cropRect != nil)==cropToLCC && lcc.sensor==sensor && lcc.exposureEV==exposureEV && lcc.protectHighlights==protectHighlights && lcc.cameraBody==cameraBody && lcc.bodyOrientation==bodyOrientation
    }
    func stitch() {
        guard let plan, let window, canStitch else { return }
        let profile=lensProfiles.first {$0.id.uuidString==selectedLensProfileID}
        let manifest=PanoramaManifest(plan:plan,profileID:profile?.id,profileName:profile?.name,
            offsetMM:positionReference != nil || estimatedReference != nil ? lccOffset:nil,
            sensor:sensor,bodyOrientation:bodyOrientation)
        let controller=PanoramaExportController(plan:plan,manifest:manifest)
        controller.onExported=onExported
        controller.onQueued={ [weak self] in self?.exportWindow=nil;self?.window?.close() }
        exportWindow=controller
        controller.present(in:window)
    }
}

private struct PanoramaWorkspace: View {
    @ObservedObject var model: PanoramaWindowModel
    var body: some View {
        Group {
            if model.choosingMode { modeSelection }
            else { workspace }
        }
        .alert(L10n.tr("8b92765d86d0"),isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) {
            Button(L10n.tr("f867f3417859"),role:.cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented:Binding(get:{model.editingPosition != nil},set:{if !$0 {model.editingPosition=nil}})) {
            if let index=model.editingPosition,let plan=model.plan,let sensor=model.sensor {
                let position=model.knownPositions[index] ?? model.overviewReference?.position(of:index,in:plan,sensor:sensor) ?? .zero
                PanoramaPositionEntry(filename:plan.sources[index].url.lastPathComponent,position:position,
                    isReference:model.positionReference?.sourceIndex==index || model.positionReference==nil,hasPosition:model.knownPositions[index] != nil) { x,y,asReference in
                    model.editingPosition=nil;model.setPositionReference(index:index,x:x,y:y,asReference:asReference)
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
                Button(L10n.tr("0f638e919d73")) { model.prepare() }.buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:8) {
                Label { Text(L10n.tr("713e40499206")) } icon: { PanoramaModeIcon(perspective:true) }.font(.title2)
                Text(L10n.tr("45da88d7b38d")).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(.quinary,in:RoundedRectangle(cornerRadius:14))
            Text(L10n.tr("62fd2de26931"))
                .font(.callout).foregroundStyle(.secondary)
        }.padding(48).frame(maxWidth:720).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var workspace: some View {
        VStack(spacing:0) {
            HStack(spacing:0) {
                ZStack {
                    Color(nsColor:.underPageBackgroundColor)
                    if let cg = model.plan?.preview {
                        PanoramaHDRPreview(image:cg).padding(18)
                    } else {
                        VStack(spacing:14) {
                            Image(systemName:"panorama").font(.system(size:52)).foregroundStyle(.secondary)
                            Text(model.busy ? L10n.tr("248c5f929e45") : L10n.tr("e885a990b960"))
                            if !model.busy { Button(L10n.tr("03b1a13cf2c0")) { model.prepare() } }
                        }
                    }
                    if model.busy { VStack { Spacer(); ProgressView(model.status).padding(16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) }.padding(20) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
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
    private var inspector: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.tr("e0a7acc067fd")).font(.title2.bold())
            VStack(alignment:.leading,spacing:6) {
                Text(L10n.tr("dcd3ee9cec9b")).font(.headline)
                Picker(L10n.tr("ee38b80c37d9"),selection:Binding(get:{model.cameraBody},set:{model.setBody($0)})) {
                    ForEach(PanoramaCameraBody.allCases) {Text($0.name).tag($0)}
                }.labelsHidden()
                PanoramaBodyOrientationPicker(cameraBody:model.cameraBody,selection:Binding(get:{model.bodyOrientation},set:{model.setBodyOrientation($0)}))
                Text(model.cameraBody.travel(at:model.bodyOrientation).summary).font(.caption).foregroundStyle(.secondary)
            }
            if let plan = model.plan {
                PanoramaPositionOverview(plan:plan,sensor:model.sensor,reference:model.overviewReference,cameraBody:model.cameraBody,bodyOrientation:model.bodyOrientation) {index in model.editingPosition=index}
                    .frame(height:200).background(Color(nsColor:.underPageBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                Text(model.overviewReference != nil ? L10n.tr("a1d86877af02") : L10n.tr("92edb20a3dbc"))
                    .font(.caption).foregroundStyle(.secondary)
                if !plan.isRegistered {Text(L10n.tr("de949bd06103")).font(.caption).foregroundStyle(.orange)}
                Text(L10n.tr("5e76d67d4617" , String(describing: (model.knownPositions.count)))).font(.caption).foregroundStyle(.secondary)
                if model.knownPositions.count>1 || !plan.isRegistered {
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
            Text(model.positionReference == nil ? (model.plan?.optical.explanation ?? L10n.tr("9f661eaa4c1a")) : L10n.tr("93fa020baa18")).font(.caption).foregroundStyle(.secondary)
            if model.positionReference == nil,let plan = model.plan, let center = plan.optical.center, let sensor = model.sensor {
                Text(L10n.tr("73281fd9d6f5" , String(format: "%.1f", (center.x-plan.origins[0].x-plan.sources[0].size.width/2)*sensor.width/plan.sources[0].size.width), String(format: "%.1f", (center.y-plan.origins[0].y-plan.sources[0].size.height/2)*sensor.height/plan.sources[0].size.height)))
                    .font(.caption)
            }
            if let reference=model.positionReference,let plan=model.plan {
                Text(L10n.tr("a6805c058eaa" , String(describing: (plan.sources[reference.sourceIndex].url.lastPathComponent)), String(format: "%+.1f", reference.positionMM.x), String(format: "%+.1f", reference.positionMM.y))).font(.caption)
                Button(L10n.tr("47966d105fad")) {model.positionReference=nil;model.estimatedReference=nil;model.lccOffset = .zero;model.changeLCC()}
            } else if model.estimatedReference != nil {
                Text(model.positionExplanation).font(.caption).foregroundStyle(.secondary)
            }
            Picker(L10n.tr("185ffacaf4ad"),selection:$model.selectedLensProfileID) {
                Text(L10n.tr("d03dcdd057a2")).tag("")
                ForEach(model.lensProfiles) { Text($0.name).tag($0.id.uuidString) }
            }.onChange(of:model.selectedLensProfileID) { _,_ in model.selectLensProfile(); model.changeLCC() }
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
            Toggle(L10n.tr("945ac5c3da15"),isOn:$model.lccEnabled).toggleStyle(.checkbox)
                .disabled(model.plan?.isRegistered != true)
                .onChange(of:model.lccEnabled) {_,enabled in model.changeLCC(automaticallyLocate:enabled)}
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
                Button(L10n.tr("693a0e217822")) {model.alignLCC()}.disabled(model.positionReference != nil)
                Button(L10n.tr("45d14f0c4f3d")) {model.solvePosition()}.disabled(model.positionReference != nil)
                Text(L10n.tr("3b0da2de91ba")).font(.caption)
                HStack {Text(L10n.tr("4626a2810ff9"));Spacer();Text(String(format:"%+.2f EV",model.exposureEV)).monospacedDigit()}
                Slider(value:$model.exposureEV,in:-4...4,step:0.05,onEditingChanged:{editing in if !editing {model.changeLCC()}})
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
                Toggle(L10n.tr("2444feb8c1fc"),isOn:$model.protectHighlights).toggleStyle(.checkbox)
                    .onChange(of:model.protectHighlights) {_,_ in model.changeLCC()}
                if model.protectHighlights,let ev=model.plan?.lccState?.highlightEV {
                    Text(L10n.tr("b1df88bb7bb6" , String(format: "%.2f", ev))).font(.caption).foregroundStyle(.secondary)
                }
                Text(model.positionReference == nil ? L10n.tr("571a6cd6f748") : L10n.tr("531e654e1a1e")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(L10n.tr("71e8dddcf62b")).font(.headline)
            Toggle(L10n.tr("dcc5dc5e40cb"),isOn:$model.options.avoidMotion).onChange(of:model.options.avoidMotion) { _,_ in model.refresh() }
            Toggle(L10n.tr("f332d17f7e09"),isOn:$model.options.matchExposure).onChange(of:model.options.matchExposure) { _,_ in model.refresh() }
            Text(L10n.tr("802a18c71f09")).font(.callout)
            Slider(value:$model.options.seamSoftness,in:0...12,step:1,onEditingChanged:{ editing in if !editing { model.refresh() } })
            Picker(L10n.tr("f55043412c64"),selection:$model.options.preferredSource) {
                Text(L10n.tr("db9773faa309")).tag(-1)
                ForEach(Array(model.urls.enumerated()),id:\.offset) { i,url in Text(url.lastPathComponent).tag(i) }
            }.onChange(of:model.options.preferredSource) { _,_ in model.refresh() }
            Text(L10n.tr("95875297cbcd")).font(.caption).foregroundStyle(.secondary)
            Divider()
            Button(L10n.tr("9e4be2d889be")) { model.manageLCC() }
            Text(L10n.tr("26747f634b19" , String(describing: (model.lccCount)), String(describing: (model.urls.count)))).font(.caption).foregroundStyle(.secondary)

        }.disabled(model.busy)
        .onChange(of:model.sensorChoice) {_,_ in model.selectLensProfile();if model.lccEnabled {model.changeLCC()}}
        .onChange(of:model.sensorWidth) {_,_ in model.selectLensProfile();if model.lccEnabled {model.changeLCC()}}
        .onChange(of:model.sensorHeight) {_,_ in model.selectLensProfile();if model.lccEnabled {model.changeLCC()}}
    }
}

private struct PanoramaPositionEntry:View {
    let filename:String
    let hasPosition:Bool
    let onSave:(Double,Double,Bool)->Void
    let onClear:()->Void
    let onCancel:()->Void
    @State private var x:String
    @State private var y:String
    @State private var isReference:Bool
    init(filename:String,position:CGPoint,isReference:Bool,hasPosition:Bool,onSave:@escaping(Double,Double,Bool)->Void,onClear:@escaping()->Void,onCancel:@escaping()->Void) {
        self.filename=filename;self.hasPosition=hasPosition;self.onSave=onSave;self.onClear=onClear;self.onCancel=onCancel
        _x=State(initialValue:hasPosition ? String(format:"%.2f",position.x):"");_y=State(initialValue:hasPosition ? String(format:"%.2f",position.y):"")
        _isReference=State(initialValue:isReference)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.tr("26de880334ca")).font(.title2.bold())
            Text(filename).font(.headline)
            Text(L10n.tr("5851c578611d")).font(.callout)
            HStack {Text(L10n.tr("98ab61de3e93"));TextField("mm",text:$x);Text("mm")}
            HStack {Text(L10n.tr("5e9009b476b1"));TextField("mm",text:$y);Text("mm")}
            Toggle(L10n.tr("13097721eadb"),isOn:$isReference).toggleStyle(.checkbox)
            Text(L10n.tr("096e62731d90")).font(.caption).foregroundStyle(.secondary)
            HStack {Button(L10n.tr("44acfaf249fe"),action:onClear).disabled(!hasPosition);Spacer();Button(L10n.tr("2cd0f3be8738"),action:onCancel);Button(L10n.tr("d977ab79b013")) {if let x=Double(x),let y=Double(y) {onSave(x,y,isReference)}}
                .buttonStyle(.borderedProminent).disabled((Double(x).map {!$0.isFinite || abs($0)>150} ?? true) || (Double(y).map {!$0.isFinite || abs($0)>150} ?? true))}
        }.padding(24).frame(width:420).textFieldStyle(.roundedBorder)
    }
}

private struct PanoramaPositionOverview: View {
    let plan: PanoramaPlan
    let sensor: SensorSize?
    let reference:PanoramaPositionReference?
    let cameraBody:PanoramaCameraBody
    let bodyOrientation:PanoramaBodyOrientation
    let onSelect:(Int)->Void
    private let colors: [Color] = [.cyan,.purple,.green,.pink,.yellow,.blue]
    private func geometry(_ canvas:CGSize)->(photos:[CGRect],body:CGRect?,factor:Double,offset:CGPoint) {
        let photos:[CGRect]
        var body:CGRect?
        if let sensor {
            photos=plan.sources.indices.map {i in
                let r=plan.sourceRect(i)
                let c=reference?.position(of:i,in:plan,sensor:sensor) ?? CGPoint(
                    x:(r.midX-plan.size.width/2)*sensor.width/r.width,
                    y:(plan.size.height/2-r.midY)*sensor.height/r.height)
                return CGRect(x:c.x-sensor.width/2,y:-c.y-sensor.height/2,width:sensor.width,height:sensor.height)
            }
            // The range is a frame footprint swept over the entire camera travel. Without a
            // measured reference, center its bounding rectangle on the panorama, not the axis.
            body=cameraBody.travel(at:bodyOrientation).coverage(sensor:sensor,centered:reference==nil)
        } else {photos=plan.sources.indices.map {plan.sourceRect($0)}}
        var bounds=photos.reduce(CGRect.null) {$0.union($1)}
        if let body {bounds=bounds.union(body)}
        let factor=min((canvas.width-28)/bounds.width,(canvas.height-40)/bounds.height)
        let offset=CGPoint(x:(canvas.width-bounds.width*factor)/2-bounds.minX*factor,
                           y:(canvas.height-bounds.height*factor)/2-bounds.minY*factor+4)
        func display(_ r:CGRect)->CGRect {CGRect(x:r.minX*factor+offset.x,y:r.minY*factor+offset.y,width:r.width*factor,height:r.height*factor)}
        return (photos.map(display),body.map(display),factor,offset)
    }
    var body: some View {
        GeometryReader { proxy in
            let layout=geometry(proxy.size)
            Canvas { context, canvas in
                if let body=layout.body {
                    context.fill(Path(body),with:.color(.primary.opacity(0.025)))
                    context.stroke(Path(body),with:.color(.primary.opacity(0.65)),style:StrokeStyle(lineWidth:1.2,dash:[5,3]))
                    context.draw(Text(L10n.tr("fe8af84b5fd4" , String(describing: (cameraBody.name)), String(describing: (bodyOrientation.rawValue)))).font(.system(size:9)).foregroundColor(.secondary),at:CGPoint(x:body.midX,y:body.minY-9))
                }
                for i in plan.sources.indices {
                    let rect=layout.photos[i],color=colors[i%colors.count]
                    let position=sensor.flatMap {reference?.position(of:i,in:plan,sensor:$0)}
                    let outside=position.map {!cameraBody.travel(at:bodyOrientation).contains($0)} ?? false
                    context.fill(Path(rect),with:.color(color.opacity(0.14)))
                    context.stroke(Path(rect),with:.color(outside ? .orange:color),lineWidth:reference?.sourceIndex==i ? 2.5:1.2)
                    context.draw(Text(plan.sources[i].url.lastPathComponent).font(.system(size:10,weight:.medium)).foregroundColor(.primary),at:CGPoint(x:rect.midX,y:rect.midY))
                    if let sensor {
                        let r=plan.sourceRect(i)
                        let delta=CGPoint(x:(r.midX-plan.size.width/2)/r.width*sensor.width,y:(plan.size.height/2-r.midY)/r.height*sensor.height)
                        let c=position ?? delta
                        let coordinates=String(format:position == nil ? "Δ %+.1f, %+.1f mm":"X %+.1f · Y %+.1f mm",c.x,c.y)
                        context.draw(Text(coordinates).font(.system(size:8)).foregroundColor(.secondary),at:CGPoint(x:rect.midX,y:rect.midY+13))
                    }
                }
                if reference==nil {
                    context.draw(Text(L10n.tr("00964853f102")).font(.system(size:8)).foregroundColor(.secondary),at:CGPoint(x:canvas.width/2,y:canvas.height-8))
                }
            }.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded {value in
                guard sensor != nil else {return}
                // In overlaps, choose the nearest frame center instead of a paint-order winner.
                let choices=plan.sources.indices.filter {layout.photos[$0].contains(value.location)}
                if let i=choices.min(by:{a,b in
                    hypot(layout.photos[a].midX-value.location.x,layout.photos[a].midY-value.location.y)
                    < hypot(layout.photos[b].midX-value.location.x,layout.photos[b].midY-value.location.y)
                }) {onSelect(i)}
            })
        }
    }
}
