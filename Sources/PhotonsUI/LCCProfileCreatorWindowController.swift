import AppKit
import SwiftUI
import PhotonsPanorama

@MainActor
final class LCCProfileCreatorWindowController: NSWindowController, NSWindowDelegate {
    private let model=LCCProfileCreatorModel()
    var onClose:(()->Void)?
    init(onCreated:@escaping (LCCProfileSummary)->Void) {
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title="创建镜头 Profile";w.minSize=NSSize(width:900,height:680);w.isReleasedWhenClosed=false
        super.init(window:w);w.delegate=self;model.window=w;model.onCreated=onCreated
        let hosting=NSHostingView(rootView:LCCProfileCreatorView(model:model))
        // Adding per-frame metadata must scroll the inspector, not enlarge the window
        // beyond the display and push the creation controls off screen.
        hosting.sizingOptions=[];w.contentView=hosting;w.center()
    }
    required init?(coder:NSCoder) { fatalError("no nib") }
    func windowWillClose(_ notification:Notification) { model.close();onClose?() }
}

@MainActor
private final class LCCProfileCreatorModel: ObservableObject {
    weak var window:NSWindow?
    var onCreated:((LCCProfileSummary)->Void)?
    @Published var name=""
    @Published var apertureText=""
    @Published var notes=""
    @Published var sensorLong=43.8
    @Published var sensorShort=32.9
    @Published var cameraBody:PanoramaCameraBody = .alpa12Max
    @Published var frames:[LCCCreationFrame]=[]
    @Published var selected:UUID?
    @Published var busy=false
    @Published var status="选择 LCC 白板照片，然后逐张填写并确认移轴量。"
    @Published var error:String?
    @Published var savedURL:URL?
    private var closed=false
    private var token=PanoramaCancellation()
    private let queue=DispatchQueue(label:"Photons.lcc.profile.creator",qos:.userInitiated)
    var selectedIndex:Int? { frames.firstIndex { $0.id==selected } }
    var canCreate:Bool {
        !busy && savedURL==nil && !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !frames.isEmpty &&
        frames.allSatisfy { $0.shiftConfirmed && $0.shiftX.isFinite && $0.shiftY.isFinite && abs($0.shiftX)<=150 && abs($0.shiftY)<=150 } &&
        LCCProfileBuilder.exposureIssue(frames)==nil && (5...100).contains(sensorShort) && sensorLong>=sensorShort && sensorLong<=100
    }
    func close() { closed=true;token.cancel() }
    func cancel() { token.cancel() }
    func setBody(_ body:PanoramaCameraBody) {
        cameraBody=body
        for i in frames.indices {
            frames[i].bodyOrientation=body.canonicalOrientation(frames[i].bodyOrientation)
            frames[i].shiftConfirmed=false
        }
    }
    func applyDirectionToAll(_ direction:PanoramaBodyOrientation) {
        for i in frames.indices where frames[i].bodyOrientation != direction {
            frames[i].bodyOrientation=direction;frames[i].shiftConfirmed=false
        }
    }
    func choose() {
        guard let window else { return }
        let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        panel.message="多选用相同曝光、同一光圈和同一后背拍摄的 LCC 白板照片。"
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let self else { return };self.add(panel.urls)
        }
    }
    func add(_ urls:[URL]) {
        let old=Set(frames.map { $0.source.url.standardizedFileURL })
        let fresh=Array(Set(urls.map(\.standardizedFileURL))).filter { !old.contains($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard frames.count+fresh.count<=256 else { error="一个 profile 最多包含 256 张白板。";return }
        guard !fresh.isEmpty else { return }
        busy=true;status="读取 LCC 缩略图和曝光信息…";token=PanoramaCancellation();let token=self.token
        queue.async { [weak self] in
            do {
                var frames:[LCCCreationFrame]=[]
                for url in fresh { try token.check();frames.append(try LCCCreationFrame(url:url)) }
                try token.check()
                DispatchQueue.main.async {
                    guard let self,!self.closed else { return }
                    if self.frames.isEmpty,let sensor=frames.first?.source.sensor { self.sensorLong=max(sensor.width,sensor.height);self.sensorShort=min(sensor.width,sensor.height) }
                    self.frames+=frames;self.selected=self.selected ?? frames.first?.id;self.busy=false
                    self.status="已读取 \(self.frames.count) 张。文件名中的移轴量仅为建议，请核对后确认。"
                }
            } catch { DispatchQueue.main.async { self?.finish(error) } }
        }
    }
    func removeSelected() {
        guard let id=selected else { return };frames.removeAll { $0.id==id };selected=frames.first?.id
    }
    func create() {
        guard canCreate else { return }
        let aperture:Double?
        if apertureText.trimmingCharacters(in:.whitespaces).isEmpty { aperture=nil }
        else if let n=Double(apertureText),n.isFinite,n>0,n<=128 { aperture=n }
        else { error="请填写有效光圈值，例如 11。";return }
        busy=true;status="建立镜头标定…";token=PanoramaCancellation()
        let token=self.token,frames=self.frames,name=self.name,notes=self.notes,long=self.sensorLong,short=self.sensorShort,body=self.cameraBody
        queue.async { [weak self] in
            do {
                let profile=try LCCProfileBuilder.create(name:name,aperture:aperture,notes:notes,frames:frames,
                    sensorLongEdge:long,sensorShortEdge:short,cameraBody:body,cancellation:token) { message in
                        DispatchQueue.main.async { self?.status=message }
                    }
                try token.check()
                let url=try LCCProfileStore().save(profile)
                let bytes=(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
                DispatchQueue.main.async {
                    guard let self,!self.closed else { return }
                    self.busy=false;self.savedURL=url
                    self.status="创建成功 · \(ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file)) · 已保存到本机应用数据"
                    self.onCreated?(LCCProfileSummary(profile))
                }
            } catch { DispatchQueue.main.async { self?.finish(error) } }
        }
    }
    private func finish(_ error:Error) {
        guard !closed else { return };busy=false
        if error is CancellationError { status="已取消，可继续编辑。" }
        else { self.error=error.localizedDescription;status="未创建 profile，请检查输入。" }
    }
}

private struct LCCProfileCreatorView: View {
    @ObservedObject var model:LCCProfileCreatorModel
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("创建镜头 Profile").font(.title.bold())
            Text("请用 LCC 板，以相同曝光（ISO、快门）、同一光圈和对焦设置，拍摄不同移轴量的白板照片。后背相对机身的横竖方向分别标定；整机一起旋转可复用原标定。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                TextField("镜头名称，例如 APO-Digitar 43XL + iiic",text:$model.name)
                Text("f/");TextField("光圈",text:$model.apertureText).frame(width:55)
                Button("添加白板照片…") { model.choose() }
            }.textFieldStyle(.roundedBorder).disabled(model.busy || model.savedURL != nil)
            Picker("拍摄机身",selection:Binding(get:{model.cameraBody},set:{model.setBody($0)})) {
                ForEach(PanoramaCameraBody.allCases) {Text($0.name).tag($0)}
            }.frame(width:300).disabled(model.busy || model.savedURL != nil)
            HSplitView {
                VStack(alignment:.leading,spacing:10) {
                    HStack { Text("\(model.frames.count) 张 · 已确认 \(model.frames.filter(\.shiftConfirmed).count) 张");Spacer();Button("移除选中") { model.removeSelected() }.disabled(model.selected==nil) }.font(.caption)
                    ScrollView {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:145),spacing:12)],spacing:12) {
                            ForEach(model.frames) { frame in
                                Button { model.selected=frame.id } label: {
                                    VStack(spacing:6) {
                                        if let cg=frame.thumbnail { Image(decorative:cg,scale:1).resizable().aspectRatio(contentMode:.fit).frame(height:105) }
                                        else { Image(systemName:"photo").frame(height:105) }
                                        Text(frame.source.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                                        Text("机身 \(frame.bodyOrientation.rawValue)° · 后背相对\(frame.relativeOrientation.title)").font(.caption2).foregroundStyle(.secondary)
                                        Label(frame.shiftConfirmed ? String(format:"H %+.1f / V %+.1f mm",frame.shiftX,frame.shiftY):"待确认移轴量",systemImage:frame.shiftConfirmed ? "checkmark.circle.fill":"circle")
                                            .font(.caption2).foregroundStyle(frame.shiftConfirmed ? Color.green:Color.orange)
                                    }.padding(8).frame(maxWidth:.infinity)
                                        .background(model.selected==frame.id ? Color.accentColor.opacity(0.15):Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                                }.buttonStyle(.plain)
                            }
                        }.padding(4)
                        if model.frames.isEmpty { ContentUnavailableView("添加 LCC 白板",systemImage:"camera.metering.center.weighted",description:Text("支持多选文件。选中缩略图后，在右侧输入该张移轴量。")) }
                    }
                }.frame(minWidth:460)
                inspector.frame(width:290).padding(.leading,12)
            }.frame(minHeight:0,maxHeight:.infinity).disabled(model.busy || model.savedURL != nil)
            if let issue=LCCProfileBuilder.exposureIssue(model.frames) { Text(issue).font(.caption).foregroundStyle(.orange) }
            if model.frames.contains(where: { $0.iso==nil || $0.exposureSeconds==nil }) {
                Text("部分照片没有曝光元数据，请根据拍摄记录确认整组曝光相同。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.busy { Button("取消") { model.cancel() } }
                if let url=model.savedURL {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("完成") { model.window?.close() }.buttonStyle(.borderedProminent)
                } else { Button("创建 Profile") { model.create() }.buttonStyle(.borderedProminent).disabled(!model.canCreate) }
            }
        }.padding(22)
        .alert("创建镜头 Profile",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) { Button("好") {model.error=nil} } message: { Text(model.error ?? "") }
    }
    private var inspector:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                if let i=model.selectedIndex {
                    Text(model.frames[i].source.url.lastPathComponent).font(.headline).textSelection(.enabled)
                    Text("拍摄时的机身方向").font(.headline)
                    PanoramaBodyOrientationPicker(cameraBody:model.cameraBody,selection:$model.frames[i].bodyOrientation)
                        .onChange(of:model.frames[i].bodyOrientation) {_,_ in model.frames[i].shiftConfirmed=false}
                    Button("将此机身方向用于全部照片") {model.applyDirectionToAll(model.frames[i].bodyOrientation)}.controlSize(.small)
                    Picker("照片方向（RAW）",selection:$model.frames[i].orientation) {
                        ForEach(LCCCaptureOrientation.allCases) { Text($0.title).tag($0) }
                    }.onChange(of:model.frames[i].orientation) {_,_ in model.frames[i].shiftConfirmed=false}
                    Text("后背相对机身：\(model.frames[i].relativeOrientation.title)").font(.caption).foregroundStyle(.secondary)
                    Text("移轴量（mm）").font(.headline)
                    HStack { Text("水平 H").frame(width:65,alignment:.leading);TextField("mm",value:$model.frames[i].shiftX,format:.number) }
                    HStack { Text("垂直 V").frame(width:65,alignment:.leading);TextField("mm",value:$model.frames[i].shiftY,format:.number) }
                    Text("按画面方向填写：右 R / 上 U 为正；左 L / 下 D 为负。机身旋转后，请先将刻度换算到画面方向。保存时会与白板测量一起转换到机身坐标。").font(.caption).foregroundStyle(.secondary)
                    Toggle("已核对这张的方向和移轴量",isOn:$model.frames[i].shiftConfirmed)
                    Text(model.frames[i].source.camera).font(.caption)
                    Text("ISO \(model.frames[i].iso.map { String(format:"%.0f",$0) } ?? "未知") · \(model.frames[i].exposureSeconds.map { String(format:"%.4g 秒",$0) } ?? "快门未知")").font(.caption).foregroundStyle(.secondary)
                } else { Text("选择左侧照片，填写对应的移轴量。").foregroundStyle(.secondary) }
                Divider()
                Text("传感器尺寸（mm）").font(.headline)
                HStack { Text("长边");TextField("mm",value:$model.sensorLong,format:.number);Text("短边");TextField("mm",value:$model.sensorShort,format:.number) }
                HStack {
                    Button("44 × 33") {model.sensorLong=43.8;model.sensorShort=32.9}
                    Button("54 × 40") {model.sensorLong=54;model.sensorShort=40}
                    Button("36 × 24") {model.sensorLong=36;model.sensorShort=24}
                }.controlSize(.small)
                Text("优先读取 RAW；识别不到时按后背的实际感光面积填写。").font(.caption).foregroundStyle(.secondary)
                TextField("备注，例如无穷远对焦",text:$model.notes,axis:.vertical).lineLimit(2...4)
                Text("Profile 保存白板的色偏、亮度测量与拍摄位置。创建后无需依赖原始 RAW；弱光角落也会保留。").font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder)
        }
    }
}
