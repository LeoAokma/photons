import AppKit
import PhotonsFileAccess
import SwiftUI
import UniformTypeIdentifiers
import PhotonsPanorama

@MainActor
public final class PanoramaWindowController: NSWindowController, NSWindowDelegate {
    private let model: PanoramaWindowModel
    public var onClose: (() -> Void)?
    public init(urls: [URL]) {
        model = PanoramaWindowModel(urls:urls)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1240,height:820),
                              styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "全景拼接"; window.minSize = NSSize(width:980,height:690); window.isReleasedWhenClosed = false
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
    @Published var exportKind = PanoramaExportKind.standard
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
    @Published var profileStatus = "正在读取镜头 profiles…"
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
        guard x.isFinite,y.isFinite,abs(x)<=150,abs(y)<=150 else {error="请输入有效的移轴位置。";return}
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
        guard let id=UUID(uuidString:selectedLensProfileID),let sensor else {error="请先选择镜头 profile 并确定传感器尺寸。";lccEnabled=false;return}
        let cached=lccSession,offset=lccOffset,crop=cropToLCC,exposure=exposureEV,protect=protectHighlights
        let wb:(Float,Float)?=automaticLCCWB ? nil:(Float(lccTemperature),Float(lccTint))
        let shouldLocate=automaticallyLocate && positionReference==nil
        let body=cameraBody,orientation=bodyOrientation
        cancellation.cancel();cancellation=PanoramaCancellation();let token=cancellation
        busy=true;error=nil;status=shouldLocate ? "正在准备 LCC 并自动解算位置…":"正在更新 LCC 校正…"
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
                        locationIssue="自动解算未完成：\(error.localizedDescription) 可点击“手动对齐lcc”调整位置。"
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
                    self.status=solution != nil ? "LCC 自动解算并已应用 · 预览与输出共用同一位置":"预览就绪 · 拼接位置已锁定"
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
            self?.plan=result;self?.lccOffset=offset;self?.status="LCC 对齐已应用 · 预览与输出共用同一校正位置"
            let r=result.sourceRect(0)
            self?.estimatedReference=PanoramaPositionReference(sourceIndex:0,positionMM:CGPoint(
                x:(r.midX-result.size.width/2)*session.sensor.width/r.width-offset.x,
                y:(result.size.height/2-r.midY)*session.sensor.height/r.height-offset.y))
            self?.positionExplanation=explanation ?? "位置由手动 LCC 对齐确定；可点击照片输入已知读数覆盖。"
        }
        c.onClose={ [weak self] in self?.alignmentWindow=nil };alignmentWindow=c;c.showWindow(nil);c.window?.makeKeyAndOrderFront(nil)
    }
    func solvePosition() {
        guard let current=plan,let session=lccSession,lccEnabled,!busy,positionReference==nil else {return}
        cancellation.cancel();cancellation=PanoramaCancellation();let token=cancellation
        busy=true;error=nil;status="正在自动解算位置…"
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
                    self.busy=false;self.status="自动解算完成，请在预览中核对并应用"
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
                    self?.profileStatus=catalog.issues.isEmpty ? "按后背型号、尺寸及后背相对机身的方向匹配。" : catalog.issues.joined(separator:"\n")
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
        case 1: value=SensorSize(width:43.8,height:32.9,source:"手动：44 × 33")
        case 2: value=SensorSize(width:54,height:40,source:"手动：54 × 40（按实际后背尺寸）")
        case 3: value=SensorSize(width:36,height:24,source:"手动：135 全画幅")
        default: value=sensorWidth>0 && sensorHeight>0 && sensorWidth<100 && sensorHeight<100 ? SensorSize(width:sensorWidth,height:sensorHeight,source:"自定义"):nil
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
                    self?.status = result.isRegistered ? "预览就绪 · 拼接位置已锁定":"配准未完成 · 请补充移轴信息后重新匹配" }
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
        if exportKind == .standard {
            let controller = PanoramaExportController(plan: plan)
            exportWindow = controller
            controller.present(in: window)
            return
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "全景.dng"
        panel.allowedContentTypes = [UTType(filenameExtension:"dng") ?? .data]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for:window) { [weak self] result in
            guard result == .OK, let destination = panel.url, let self else { return }
            self.busy = true; self.error = nil; self.cancellation = PanoramaCancellation()
            let token = self.cancellation
            let destinationAccess = FileAccess(destination)
            self.queue.async {
                defer { withExtendedLifetime(destinationAccess) {} }
                do {
                    try PanoramaEngine().export(plan,to:destination,format:.dng,cancellation:token) { message in
                        DispatchQueue.main.async { self.status = message }
                    }
                    DispatchQueue.main.async {
                        self.busy = false; self.status = "已保存：\(destination.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                } catch { DispatchQueue.main.async {
                    self.busy = false; self.status = error is CancellationError ? "已取消" : "导出失败"
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }}
            }
        }
    }
}

private struct PanoramaWorkspace: View {
    @ObservedObject var model: PanoramaWindowModel
    var body: some View {
        Group {
            if model.choosingMode { modeSelection }
            else { workspace }
        }
        .alert("全景拼接",isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) {
            Button("好",role:.cancel) { model.error = nil }
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
            Text("选择拼接模式").font(.largeTitle.bold())
            Text("已选择 \(model.urls.count) 张照片").foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:12) {
                Label { Text("移轴接片") } icon: { PanoramaModeIcon() }.font(.title2.bold())
                Text("镜头保持固定，后背平移。只移动图片位置，保留原始透视。")
                Button("开始移轴接片") { model.prepare() }.buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:8) {
                Label { Text("透视接片") } icon: { PanoramaModeIcon(perspective:true) }.font(.title2)
                Text("适用于转动相机的拍摄方式，后续版本提供。").foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(.quinary,in:RoundedRectangle(cornerRadius:14))
            Text("使用原始图像统一解码，不应用图库内的裁剪和调色。预览完成后，点击“拼接”才生成全分辨率文件。")
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
                            Text(model.busy ? "正在解算拼接位置" : "请在示意图中选择照片，补充移轴信息后重新匹配")
                            if !model.busy { Button("按移轴信息重新匹配") { model.prepare() } }
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
                    if let plan = model.plan { Text("\(Int(plan.outputSize.width)) × \(Int(plan.outputSize.height)) · \(plan.outputSize.width*plan.outputSize.height/1_000_000,specifier:"%.1f") MP · \(plan.sources.count) 张")
                        .font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.busy { Button("取消") { model.cancel() } }
                Button("拼接") { model.stitch() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStitch)
            }.padding(16)
        }
    }
    private var inspector: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("移轴接片").font(.title2.bold())
            VStack(alignment:.leading,spacing:6) {
                Text("拍摄机身").font(.headline)
                Picker("机身",selection:Binding(get:{model.cameraBody},set:{model.setBody($0)})) {
                    ForEach(PanoramaCameraBody.allCases) {Text($0.name).tag($0)}
                }.labelsHidden()
                PanoramaBodyOrientationPicker(cameraBody:model.cameraBody,selection:Binding(get:{model.bodyOrientation},set:{model.setBodyOrientation($0)}))
                Text(model.cameraBody.travel(at:model.bodyOrientation).summary).font(.caption).foregroundStyle(.secondary)
            }
            if let plan = model.plan {
                PanoramaPositionOverview(plan:plan,sensor:model.sensor,reference:model.overviewReference,cameraBody:model.cameraBody,bodyOrientation:model.bodyOrientation) {index in model.editingPosition=index}
                    .frame(height:200).background(Color(nsColor:.underPageBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                Text(model.overviewReference != nil ? "已显示相对机身的位置。点击照片可指定唯一基准；橙框表示超出行程。" : "Δ 以拼接图中心为 (0, 0)，右／上为正。点击任意照片，输入已知移轴位置。")
                    .font(.caption).foregroundStyle(.secondary)
                if !plan.isRegistered {Text("待配准示意，未确认的照片位置仅供选取。").font(.caption).foregroundStyle(.orange)}
                Text("已录入 \(model.knownPositions.count) 张移轴信息；搜索范围为读数附近 ±1.5 mm。").font(.caption).foregroundStyle(.secondary)
                if model.knownPositions.count>1 || !plan.isRegistered {
                    Button("按移轴信息重新匹配") {model.prepare()}
                    if model.alignmentNeedsUpdate {Text("移轴约束已变更，请重新匹配。").font(.caption).foregroundStyle(.orange)}
                }
            }
            Picker("传感器",selection:$model.sensorChoice) {
                Text("从 RAW 自动识别").tag(0); Text("44 × 33 · 43.8 × 32.9 mm").tag(1)
                Text("54 × 40 mm").tag(2); Text("135 · 36 × 24 mm").tag(3); Text("自定义尺寸").tag(4)
            }
            if model.sensorChoice == 4 {
                HStack { TextField("宽 mm",value:$model.sensorWidth,format:.number); Text("×"); TextField("高 mm",value:$model.sensorHeight,format:.number) }.textFieldStyle(.roundedBorder)
            }
            if let sensor = model.sensor {
                Text("\(sensor.width,specifier:"%.2f") × \(sensor.height,specifier:"%.2f") mm\n\(sensor.source)").font(.caption).foregroundStyle(.secondary)
            } else { Text("无法确定传感器尺寸，请选择规格或手动输入。相对像素位置仍然有效。").font(.caption).foregroundStyle(.orange) }
            Divider()
            Text("光学位置估计").font(.headline)
            Text(model.positionReference == nil ? (model.plan?.optical.explanation ?? "读取亮度衰减、边缘遮挡与红移后估计。") : "已知位置优先，LCC 原点由该基准确定，自动估计与手动对齐不再改变位置。").font(.caption).foregroundStyle(.secondary)
            if model.positionReference == nil,let plan = model.plan, let center = plan.optical.center, let sensor = model.sensor {
                Text("候选光轴：距第一张中心 X \((center.x-plan.origins[0].x-plan.sources[0].size.width/2)*sensor.width/plan.sources[0].size.width,specifier:"%.1f") / Y \((center.y-plan.origins[0].y-plan.sources[0].size.height/2)*sensor.height/plan.sources[0].size.height,specifier:"%.1f") mm")
                    .font(.caption)
            }
            if let reference=model.positionReference,let plan=model.plan {
                Text("位置基准：\(plan.sources[reference.sourceIndex].url.lastPathComponent)\nX \(reference.positionMM.x,specifier:"%+.1f") / Y \(reference.positionMM.y,specifier:"%+.1f") mm").font(.caption)
                Button("解除位置基准") {model.positionReference=nil;model.estimatedReference=nil;model.lccOffset = .zero;model.changeLCC()}
            } else if model.estimatedReference != nil {
                Text(model.positionExplanation).font(.caption).foregroundStyle(.secondary)
            }
            Picker("镜头 Profile",selection:$model.selectedLensProfileID) {
                Text("不选择").tag("")
                ForEach(model.lensProfiles) { Text($0.name).tag($0.id.uuidString) }
            }.onChange(of:model.selectedLensProfileID) { _,_ in model.selectLensProfile(); model.changeLCC() }
            Text(model.profileStatus).font(.caption).foregroundStyle(.secondary)
            if let plan=model.plan, !model.selectedLensProfileID.isEmpty {
                ForEach(plan.sources.indices,id:\.self) { i in
                    HStack(alignment:.top) {
                        Text(plan.sources[i].url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if plan.lensProfileSelections.indices.contains(i),let binding=plan.lensProfileSelections[i] {
                            Text("\(binding.orientation.title) · \(binding.captureCount) 张标定").foregroundStyle(.secondary)
                        } else {Text("无匹配标定").foregroundStyle(.orange)}
                    }.font(.caption)
                }
            }
            Button("镜头 Profile 管理…") {model.manageLCC(showProfiles:true)}
            Toggle("LCC校正",isOn:$model.lccEnabled).toggleStyle(.checkbox)
                .disabled(model.plan?.isRegistered != true)
                .onChange(of:model.lccEnabled) {_,enabled in model.changeLCC(automaticallyLocate:enabled)}
            if model.lccEnabled {
                if let warning=model.plan?.lccState?.warning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                    Toggle("将图片裁切到lcc覆盖范围",isOn:$model.cropToLCC).toggleStyle(.checkbox)
                        .disabled(model.plan?.lccState?.suggestedCropRect == nil)
                        .onChange(of:model.cropToLCC) {_,_ in model.changeLCC()}
                } else if model.cropToLCC {
                    Toggle("将图片裁切到lcc覆盖范围",isOn:$model.cropToLCC).toggleStyle(.checkbox)
                        .onChange(of:model.cropToLCC) {_,_ in model.changeLCC()}
                }
                Button("手动对齐lcc") {model.alignLCC()}.disabled(model.positionReference != nil)
                Button("自动解算位置") {model.solvePosition()}.disabled(model.positionReference != nil)
                Text("暗角与颜色偏移：完整校正").font(.caption)
                HStack {Text("整体曝光");Spacer();Text(String(format:"%+.2f EV",model.exposureEV)).monospacedDigit()}
                Slider(value:$model.exposureEV,in:-4...4,step:0.05,onEditingChanged:{editing in if !editing {model.changeLCC()}})
                Toggle("校正后自动白平衡",isOn:$model.automaticLCCWB).toggleStyle(.checkbox)
                    .onChange(of:model.automaticLCCWB) {_,value in
                        if !value,let wb=model.plan?.lccState?.whiteBalance {model.lccTemperature=Double(wb.0);model.lccTint=Double(wb.1)}
                        model.changeLCC()
                    }
                if let wb=model.plan?.lccState?.whiteBalance {
                    Text("\(model.plan?.lccState?.whiteBalanceSource ?? "")：\(Int(wb.0.rounded())) K · 色调 \(wb.1,specifier:"%.1f")").font(.caption).foregroundStyle(.secondary)
                }
                if !model.automaticLCCWB {
                    HStack {
                        Text("色温");TextField("K",value:$model.lccTemperature,format:.number.precision(.fractionLength(0))).onSubmit {model.changeLCC()}
                        Text("色调");TextField("Tint",value:$model.lccTint,format:.number.precision(.fractionLength(1))).onSubmit {model.changeLCC()}
                    }.textFieldStyle(.roundedBorder)
                    Button("应用白平衡") {model.changeLCC()}
                }
                Toggle("保护高光",isOn:$model.protectHighlights).toggleStyle(.checkbox)
                    .onChange(of:model.protectHighlights) {_,_ in model.changeLCC()}
                if model.protectHighlights,let ev=model.plan?.lccState?.highlightEV {
                    Text("高光保护自动曝光 \(ev,specifier:"%.2f") EV；HDR 预览与输出保留高光余量。").font(.caption).foregroundStyle(.secondary)
                }
                Text(model.positionReference == nil ? "开启 LCC 时自动解算并应用位置，也可手动对齐或重新解算。先校正 RAW 通道，再应用白平衡；预览与输出共用位置和增益。" : "LCC 已跟随位置基准锁定。清除基准后可手动对齐。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("重叠处理").font(.headline)
            Toggle("自动避开运动冲突",isOn:$model.options.avoidMotion).onChange(of:model.options.avoidMotion) { _,_ in model.refresh() }
            Toggle("匹配重叠曝光",isOn:$model.options.matchExposure).onChange(of:model.options.matchExposure) { _,_ in model.refresh() }
            Text("接缝柔化").font(.callout)
            Slider(value:$model.options.seamSoftness,in:0...12,step:1,onEditingChanged:{ editing in if !editing { model.refresh() } })
            Picker("冲突优先",selection:$model.options.preferredSource) {
                Text("自动选择").tag(-1)
                ForEach(Array(model.urls.enumerated()),id:\.offset) { i,url in Text(url.lastPathComponent).tag(i) }
            }.onChange(of:model.options.preferredSource) { _,_ in model.refresh() }
            Text("接缝可绕开冲突区域。仅有两张且背景被遮住时，自动判断可能有误，可改选优先照片。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("管理逐张 LCC…") { model.manageLCC() }
            Text("已记录 \(model.lccCount)/\(model.urls.count) 组逐张配对，白板用于自动定位与校正后的白平衡测量。“LCC校正”只应用所选镜头 Profile，不叠加白板校正。").font(.caption).foregroundStyle(.secondary)
            Picker("输出",selection:$model.exportKind) {
                Text("标准导出（与主体一致）").tag(PanoramaExportKind.standard)
                Text("16 位无损压缩 DNG").tag(PanoramaExportKind.losslessDNG)
            }
            Text(model.exportKind == .standard
                 ? "点击“拼接”打开主体导出设置，使用相同的格式、色彩空间、位深与 HDR 选项。"
                 : "DNG 为已应用白平衡的 16 位线性 RGB，使用无损压缩并保留高光余量。")
                .font(.caption).foregroundStyle(.secondary)
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
            Text("照片移轴信息").font(.title2.bold())
            Text(filename).font(.headline)
            Text("按画面方向填写：右 R／上 U 为正，左 L／下 D 为负。机身旋转后，请先将刻度换算到画面方向。输入镜头相对后背的移轴读数；若记录的是后背移动方向，请取反。").font(.callout)
            HStack {Text("水平 X");TextField("mm",text:$x);Text("mm")}
            HStack {Text("垂直 Y");TextField("mm",text:$y);Text("mm")}
            Toggle("设为整组位置基准",isOn:$isReference).toggleStyle(.checkbox)
            Text("可录入多张照片用于辅助匹配；整组只有一个绝对位置基准。清除仅移除这张照片的读数。").font(.caption).foregroundStyle(.secondary)
            HStack {Button("清除移轴信息",action:onClear).disabled(!hasPosition);Spacer();Button("取消",action:onCancel);Button("应用位置") {if let x=Double(x),let y=Double(y) {onSave(x,y,isReference)}}
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
                    context.draw(Text("\(cameraBody.name) · \(bodyOrientation.rawValue)° · 总覆盖范围").font(.system(size:9)).foregroundColor(.secondary),at:CGPoint(x:body.midX,y:body.minY-9))
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
                    context.draw(Text("范围居中示意 · 绝对位置未知").font(.system(size:8)).foregroundColor(.secondary),at:CGPoint(x:canvas.width/2,y:canvas.height-8))
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
