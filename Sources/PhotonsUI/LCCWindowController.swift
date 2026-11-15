import AppKit
import SwiftUI
import PhotonsPanorama

@MainActor
public final class LCCWindowController: NSWindowController, NSWindowDelegate {
    private let model: LCCWindowModel
    public var onClose: (() -> Void)?
    public init(urls: [URL]) {
        model = LCCWindowModel(urls:urls)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:730),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "LCC 矫正 · 逐张对应"; window.minSize = NSSize(width:800,height:560); window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self; model.window = window
        window.contentView = NSHostingView(rootView:LCCPairingView(model:model)); window.center(); model.load()
    }
    public required init?(coder:NSCoder) { fatalError("no nib") }
    public func windowWillClose(_ notification:Notification) { model.closed = true; onClose?() }
}

@MainActor
private final class LCCWindowModel: ObservableObject {
    weak var window: NSWindow?
    var closed = false
    @Published var urls: [URL]
    @Published var scenes: [PanoramaSource] = []
    @Published var flats: [LCCInspection] = []
    @Published var assignments: [Int] = []
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var selected = 0
    @Published var saved = false
    private let queue = DispatchQueue(label:"Photons.lcc",qos:.userInitiated)
    init(urls:[URL]) { self.urls = urls }
    func load() {
        busy = true; status = "读取照片和已确认的 LCC 对应关系…"
        let urls = self.urls
        queue.async { [weak self] in
            do {
                let scenes = try urls.map { try PanoramaSource(url:$0) }
                let records = LCCPairingStore().records().filter { urls.contains($0.scene) }
                let flatURLs = Array(Set(records.map(\.flat))).sorted { $0.lastPathComponent < $1.lastPathComponent }
                let flats = try flatURLs.map { try LCCInspector.inspect($0) }
                let assignments = urls.map { u in records.first(where: { $0.scene == u }).flatMap { r in flatURLs.firstIndex(of:r.flat) } ?? -1 }
                DispatchQueue.main.async {
                    guard let self, !self.closed else { return }
                    self.scenes = scenes; self.flats = flats; self.assignments = assignments; self.busy = false
                    self.saved = !scenes.isEmpty && assignments.allSatisfy { $0 >= 0 }
                    self.status = self.saved ? "已载入确认过的对应关系" : "添加 LCC 后，请逐张核对并确认对应关系"
                }
            } catch { DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription } }
        }
    }
    func choose(scenes:Bool) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = scenes ? "选择需要对应 LCC 的场景照片" : "选择单独拍摄的 LCC 平场照片"
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if scenes { self.urls = urls; self.saved = false; self.load() }
            else { self.addFlats(urls) }
        }
    }
    private func addFlats(_ urls:[URL]) {
        busy = true; status = "检查 LCC 纹理、亮度、遮挡与元数据…"
        let existing = Set(flats.map { $0.source.url })
        queue.async { [weak self] in
            do {
                let fresh = try urls.filter { !existing.contains($0) }.map { try LCCInspector.inspect($0) }
                DispatchQueue.main.async {
                    guard let self, !self.closed else { return }
                    self.flats += fresh; self.busy = false; self.saved = false
                    self.status = "LCC 已读取；文件序号不能证明拍摄位置，请核对逐张对应"
                }
            } catch { DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription } }
        }
    }
    func pairInOrder(reverse:Bool) {
        guard scenes.count == flats.count else { return }
        let order = flats.indices.sorted { flats[$0].source.url.lastPathComponent.localizedStandardCompare(flats[$1].source.url.lastPathComponent) == .orderedAscending }
        let sourceOrder = scenes.indices.sorted { scenes[$0].url.lastPathComponent.localizedStandardCompare(scenes[$1].url.lastPathComponent) == .orderedAscending }
        let target = reverse ? Array(order.reversed()) : order
        for (s,f) in zip(sourceOrder,target) { assignments[s] = f }
        saved = false; status = "已填入建议配对，请核对后点击“确认并保存对应关系”"
    }
    func issue(_ index:Int) -> String? {
        guard assignments.indices.contains(index), assignments[index]>=0, flats.indices.contains(assignments[index]) else { return "尚未选择 LCC" }
        let f = assignments[index]
        if assignments.filter({ $0 == f }).count > 1 { return "这张 LCC 被重复分配" }
        return LCCInspector.incompatibility(scene:scenes[index],flat:flats[f].source)
    }
    var canSave: Bool { !busy && !scenes.isEmpty && scenes.indices.allSatisfy { issue($0) == nil } }
    func save() {
        guard canSave else { return }
        do {
            let pairs = try scenes.indices.map { try LCCPairRecord(scene:scenes[$0].url,flat:flats[assignments[$0]].source.url,confirmed:true) }
            try LCCPairingStore().save(pairs); saved = true; status = "对应关系已保存；尚未对原图或全景应用 LCC 矫正"
        } catch { self.error = error.localizedDescription }
    }
}

private struct LCCPairingView: View {
    @ObservedObject var model:LCCWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("逐张 LCC 对应").font(.title.bold())
                    Text("先确认每张场景照片使用哪张平场照片，再开发校正处理。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择场景照片…") { model.choose(scenes:true) }
                Button("添加 LCC…") { model.choose(scenes:false) }.buttonStyle(.borderedProminent)
            }
            HStack {
                Text("\(model.scenes.count) 张场景 · \(model.flats.count) 张 LCC").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("按文件正序配对") { model.pairInOrder(reverse:false) }.disabled(model.scenes.isEmpty || model.scenes.count != model.flats.count)
                Button("按文件逆序配对") { model.pairInOrder(reverse:true) }.disabled(model.scenes.isEmpty || model.scenes.count != model.flats.count)
            }
            HSplitView {
                ScrollView {
                    VStack(spacing:8) {
                        if model.scenes.isEmpty { Text("从图库选择场景照片后打开此窗口，或点击“选择场景照片”。").foregroundStyle(.secondary).padding(30) }
                        ForEach(model.scenes.indices,id:\.self) { i in
                            VStack(alignment:.leading,spacing:8) {
                                HStack { Text(model.scenes[i].url.lastPathComponent).font(.headline); Spacer(); if model.saved { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) } }
                                Picker("对应 LCC",selection:Binding(get:{ model.assignments[i] },set:{ model.assignments[i] = $0; model.selected = i; model.saved = false })) {
                                    Text("请选择").tag(-1)
                                    ForEach(model.flats.indices,id:\.self) { f in Text(model.flats[f].source.url.lastPathComponent).tag(f) }
                                }
                                if let issue = model.issue(i) { Text(issue).font(.caption).foregroundStyle(.orange) }
                                else { Text("尺寸、方向和后背型号匹配").font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).background(i == model.selected ? Color.accentColor.opacity(0.1):Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                                .onTapGesture { model.selected = i }
                        }
                    }.padding(4)
                }.frame(minWidth:360)
                VStack(alignment:.leading,spacing:12) {
                    if model.assignments.indices.contains(model.selected), model.flats.indices.contains(model.assignments[model.selected]) {
                        let flat = model.flats[model.assignments[model.selected]]
                        Text(flat.source.url.lastPathComponent).font(.headline)
                        if let cg = flat.thumbnail { Image(decorative:cg,scale:1).resizable().aspectRatio(contentMode:.fit) }
                        Text(flat.source.camera).font(.caption)
                        Text("\(Int(flat.source.size.width)) × \(Int(flat.source.size.height))").font(.caption).foregroundStyle(.secondary)
                        Text(flat.message).font(.callout).foregroundStyle(flat.likelyFlat ? Color.secondary:Color.orange)
                    } else { Text("选择对应关系以预览 LCC").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
                    Spacer()
                    Text("LCC 识别依据平滑亮度、色偏和边缘遮挡。光圈、移轴位置等信息未必写入 RAW，元数据匹配不能代替拍摄记录。").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(minWidth:280)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("确认并保存对应关系") { model.save() }.buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }.padding(24).disabled(model.busy)
            .alert("LCC 对应",isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
