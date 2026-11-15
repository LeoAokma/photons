import AppKit
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
    weak var window: NSWindow?
    @Published var choosingMode = true
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var plan: PanoramaPlan?
    @Published var options = PanoramaOptions()
    @Published var format = PanoramaEngine.OutputFormat.dng
    @Published var sensorChoice = 0
    @Published var sensorWidth = 43.8
    @Published var sensorHeight = 32.9
    @Published var calibrated = false
    @Published var firstX = 0.0
    @Published var firstY = 0.0
    @Published var lccCount = 0
    private var lccWindow: LCCWindowController?
    private var cancellation = PanoramaCancellation()
    private let queue = DispatchQueue(label:"Photons.panorama",qos:.userInitiated)
    init(urls: [URL]) { self.urls = urls; refreshLCC() }
    func cancel() { cancellation.cancel() }
    func refreshLCC() {
        lccCount = LCCPairingStore().records().filter { urls.contains($0.scene) }.count
    }
    func manageLCC() {
        let controller = LCCWindowController(urls:urls)
        controller.onClose = { [weak self] in self?.refreshLCC(); self?.lccWindow = nil }
        lccWindow = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    var sensor: SensorSize? {
        switch sensorChoice {
        case 0: return plan?.sources.first?.sensor
        case 1: return SensorSize(width:43.8,height:32.9,source:"手动：44 × 33")
        case 2: return SensorSize(width:54,height:40,source:"手动：54 × 40（请按实际后背微调）")
        case 3: return SensorSize(width:36,height:24,source:"手动：135 全画幅")
        default: return sensorWidth>0 && sensorHeight>0 && sensorWidth<100 && sensorHeight<100
            ? SensorSize(width:sensorWidth,height:sensorHeight,source:"自定义") : nil
        }
    }
    func prepare() {
        choosingMode = false
        run { [urls,options] engine,token,progress in
            try engine.analyze(urls:urls,options:options,cancellation:token,progress:progress)
        }
    }
    func refresh() {
        guard let current = plan, !busy else { return }
        run { [options] engine,token,progress in try engine.update(current,options:options,cancellation:token,progress:progress) }
    }
    private func run(_ operation: @escaping (PanoramaEngine,PanoramaCancellation,@escaping PanoramaEngine.Progress) throws -> PanoramaPlan) {
        cancellation.cancel(); cancellation = PanoramaCancellation()
        let token = cancellation; busy = true; error = nil
        queue.async { [weak self] in
            do {
                let result = try operation(PanoramaEngine(),token) { message in DispatchQueue.main.async { self?.status = message } }
                try token.check()
                DispatchQueue.main.async { self?.plan = result; self?.busy = false; self?.status = "预览就绪 · 拼接位置已锁定" }
            } catch {
                DispatchQueue.main.async { self?.busy = false; if !(error is CancellationError) { self?.error = error.localizedDescription }; self?.status = "" }
            }
        }
    }
    func stitch() {
        guard let plan, let window, !busy else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "全景.\(format.rawValue)"
        panel.allowedContentTypes = [UTType(filenameExtension:format.rawValue) ?? .data]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for:window) { [weak self] result in
            guard result == .OK, let destination = panel.url, let self else { return }
            self.busy = true; self.error = nil; self.cancellation = PanoramaCancellation()
            let token = self.cancellation, format = self.format
            self.queue.async {
                do {
                    try PanoramaEngine().export(plan,to:destination,format:format,cancellation:token) { message in
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
    }
    private var modeSelection: some View {
        VStack(alignment:.leading,spacing:24) {
            Text("选择拼接模式").font(.largeTitle.bold())
            Text("已选择 \(model.urls.count) 张照片").foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:12) {
                Label("移轴接片",systemImage:"rectangle.on.rectangle").font(.title2.bold())
                Text("镜头保持固定，后背平移。只移动图片位置，保留原始透视。")
                Button("开始移轴接片") { model.prepare() }.buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:8) {
                Label("普通接片",systemImage:"panorama").font(.title2)
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
                        Image(decorative:cg,scale:1).resizable().aspectRatio(contentMode:.fit).padding(18)
                    } else {
                        VStack(spacing:14) {
                            Image(systemName:"panorama").font(.system(size:52)).foregroundStyle(.secondary)
                            Text(model.busy ? "正在解算拼接位置" : "尚未生成预览")
                            if !model.busy { Button("重新分析") { model.prepare() } }
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
                    if let plan = model.plan { Text("\(Int(plan.size.width)) × \(Int(plan.size.height)) · \(plan.megapixels,specifier:"%.1f") MP · \(plan.sources.count) 张")
                        .font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.busy { Button("取消") { model.cancel() } }
                Button("拼接") { model.stitch() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.plan == nil)
            }.padding(16)
        }
    }
    private var inspector: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("移轴接片").font(.title2.bold())
            VStack(alignment:.leading,spacing:6) {
                Text("拍摄机身").font(.headline)
                Picker("机身",selection:.constant(0)) { Text("Alpa 12 Max").tag(0) }.labelsHidden()
                Text("水平 ±18 mm · 上 25 / 下 18 mm").font(.caption).foregroundStyle(.secondary)
            }
            if let plan = model.plan {
                PanoramaPositionOverview(plan:plan,sensor:model.sensor,calibrated:model.calibrated,firstX:model.firstX,firstY:model.firstY)
                    .frame(height:200).background(Color(nsColor:.underPageBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                Text(model.calibrated ? "已按第一张的机身读数校准；橙框表示超出行程。" : "矩形为图像覆盖范围；当前为相对位置。")
                    .font(.caption).foregroundStyle(.secondary)
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
            Text(model.plan?.optical.explanation ?? "读取亮度衰减、边缘遮挡与红移后估计。").font(.caption).foregroundStyle(.secondary)
            if let plan = model.plan, let center = plan.optical.center, let sensor = model.sensor {
                Text("候选光轴：距第一张中心 X \((center.x-plan.origins[0].x-plan.sources[0].size.width/2)*sensor.width/plan.sources[0].size.width,specifier:"%.1f") / Y \((center.y-plan.origins[0].y-plan.sources[0].size.height/2)*sensor.height/plan.sources[0].size.height,specifier:"%.1f") mm")
                    .font(.caption)
            }
            Toggle("用第一张的机身读数校准",isOn:$model.calibrated).disabled(model.sensor == nil)
            if model.calibrated {
                HStack { Text("X"); TextField("mm",value:$model.firstX,format:.number); Text("Y"); TextField("mm",value:$model.firstY,format:.number) }.textFieldStyle(.roundedBorder)
                Text("右／上为正；后背移动方向与画面覆盖方向相反。").font(.caption).foregroundStyle(.secondary)
            }
            Picker("镜头",selection:.constant(0)) { Text("APO-Digitar 43XL + iiic").tag(0) }
            Text("光学配置已预留，校正参数待添加。").font(.caption).foregroundStyle(.secondary)
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
            Text("已确认 \(model.lccCount)/\(model.urls.count) 组；本版仅保存对应关系，暂不应用矫正。").font(.caption).foregroundStyle(.secondary)
            Picker("输出",selection:$model.format) {
                Text("16 位无损压缩 DNG").tag(PanoramaEngine.OutputFormat.dng)
                Text("16 位 TIFF").tag(PanoramaEngine.OutputFormat.tiff)
            }
            Text("DNG 为已去马赛克的线性 RGB，保留高光余量。未覆盖区域输出为黑色，可随后裁剪。").font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy)
    }
}

private struct PanoramaPositionOverview: View {
    let plan: PanoramaPlan
    let sensor: SensorSize?
    let calibrated: Bool
    let firstX: Double
    let firstY: Double
    private let colors: [Color] = [.cyan,.purple,.green,.pink,.yellow,.blue]
    var body: some View {
        Canvas { context, canvas in
            let margin = 16.0
            let factor = min((canvas.width-margin*2)/plan.size.width,(canvas.height-margin*2)/plan.size.height)
            let dx = (canvas.width-plan.size.width*factor)/2, dy = (canvas.height-plan.size.height*factor)/2
            for i in plan.sources.indices {
                let source = plan.sourceRect(i)
                let rect = CGRect(x:dx+source.minX*factor,y:dy+source.minY*factor,width:source.width*factor,height:source.height*factor)
                let color = colors[i%colors.count]
                var outOfRange = false
                if calibrated, let sensor {
                    // Sensor travel and captured scene displacement have opposite signs.
                    let x = firstX-(plan.origins[i].x-plan.origins[0].x)/plan.sources[0].size.width*sensor.width
                    let y = firstY+(plan.origins[i].y-plan.origins[0].y)/plan.sources[0].size.height*sensor.height
                    outOfRange = x < -18 || x > 18 || y < -18 || y > 25
                }
                context.fill(Path(rect),with:.color(color.opacity(0.14)))
                context.stroke(Path(rect),with:.color(outOfRange ? .orange:color),lineWidth:1.5)
                let label = Text(plan.sources[i].url.lastPathComponent).font(.system(size:10,weight:.medium)).foregroundColor(.primary)
                context.draw(label,at:CGPoint(x:rect.midX,y:rect.midY))
                if let sensor {
                    let dxMM = (plan.origins[i].x-plan.origins[0].x)/plan.sources[0].size.width*sensor.width
                    let dyMM = -(plan.origins[i].y-plan.origins[0].y)/plan.sources[0].size.height*sensor.height
                    let coordinates = calibrated
                        ? String(format:"X %+.1f · Y %+.1f mm",firstX-dxMM,firstY-dyMM)
                        : String(format:"Δ %+.1f, %+.1f mm",dxMM,dyMM)
                    context.draw(Text(coordinates).font(.system(size:8)).foregroundColor(.secondary),
                                 at:CGPoint(x:rect.midX,y:rect.midY+13))
                }
            }
        }
    }
}
