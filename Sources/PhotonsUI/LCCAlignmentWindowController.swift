import AppKit
import SwiftUI
import PhotonsPanorama

// Immutable session snapshots are shared with the serial preview worker.
final class LCCEditingSession: @unchecked Sendable {
    let profile:LCCLensProfile
    let fields:[LCCCaptureOrientation:LCCCorrectionField]
    let sensor:SensorSize
    let preparedPlan:PanoramaPlan
    init(plan:PanoramaPlan,profileID:UUID,sensor:SensorSize,engine:PanoramaEngine,token:PanoramaCancellation,progress:@escaping PanoramaEngine.Progress) throws {
        profile=try LCCProfileStore().load(profileID);self.sensor=sensor
        var fields:[LCCCaptureOrientation:LCCCorrectionField]=[:]
        for orientation in profile.orientations {
            try token.check();progress("建立 \(orientation.title) LCC 校正场…")
            fields[orientation]=try LCCCorrectionField(profile:profile,orientation:orientation,cancellation:token)
        }
        self.fields=fields
        preparedPlan=try engine.prepareLCCImages(plan,cancellation:token,progress:progress)
    }
}

@MainActor
final class LCCAlignmentWindowController:NSWindowController,NSWindowDelegate {
    private let model:LCCAlignmentModel
    var onClose:(()->Void)?
    init(plan:PanoramaPlan,session:LCCEditingSession,offset:CGPoint,crop:Bool,explanation:String?=nil,onApply:@escaping (PanoramaPlan,CGPoint)->Void) {
        model=LCCAlignmentModel(plan:plan,session:session,offset:offset,crop:crop,explanation:explanation,onApply:onApply)
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:800),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title="手动对齐 LCC";w.minSize=NSSize(width:900,height:650);w.isReleasedWhenClosed=false
        super.init(window:w);w.delegate=self;model.window=w
        w.contentView=NSHostingView(rootView:LCCAlignmentView(model:model));w.center();model.schedule()
    }
    required init?(coder:NSCoder) {fatalError("no nib")}
    func windowWillClose(_ notification:Notification) {model.close();onClose?()}
}

@MainActor
private final class LCCAlignmentModel:ObservableObject {
    weak var window:NSWindow?
    let base:PanoramaPlan
    let session:LCCEditingSession
    let crop:Bool
    let explanation:String?
    let onApply:(PanoramaPlan,CGPoint)->Void
    @Published var x:Double
    @Published var y:Double
    @Published var preview:PanoramaPlan
    @Published var working=false
    @Published var committing=false
    @Published var showOutline=true
    @Published var error:String?
    private var token=PanoramaCancellation()
    private var pending:DispatchWorkItem?
    private var closed=false
    private let queue=DispatchQueue(label:"Photons.lcc.alignment",qos:.userInitiated)
    init(plan:PanoramaPlan,session:LCCEditingSession,offset:CGPoint,crop:Bool,explanation:String?,onApply:@escaping (PanoramaPlan,CGPoint)->Void) {
        base=plan;self.session=session;self.crop=crop;self.onApply=onApply;x=offset.x;y=offset.y;preview=plan
        self.explanation=explanation
    }
    func close() {closed=true;pending?.cancel();token.cancel()}
    func schedule() {
        guard !closed,!committing else {return};pending?.cancel();token.cancel();working=true
        let work=DispatchWorkItem { [weak self] in self?.render(commit:false) };pending=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.12,execute:work)
    }
    func render(commit:Bool) {
        guard x.isFinite,y.isFinite else {error="请输入有效的对齐位置。";working=false;return}
        pending?.cancel();token.cancel();token=PanoramaCancellation();let token=self.token
        let offset=CGPoint(x:x,y:y),base=self.base,session=self.session,crop=self.crop
        working=true;committing=commit
        queue.async { [weak self] in
            do {
                let result=try PanoramaEngine().applyingLCC(base,profile:session.profile,fields:session.fields,offsetMM:offset,
                    sensor:session.sensor,crop:commit && crop,cancellation:token,rebuildSeams:false,
                    exposureEV:base.lccState?.exposureEV ?? 0,protectHighlights:base.lccState?.protectHighlights ?? true,whiteBalanceOverride:commit && base.lccState?.whiteBalanceWasManual != true ? nil:base.lccState?.whiteBalance,
                    cameraBody:base.lccState?.cameraBody,bodyOrientation:base.lccState?.bodyOrientation ?? .degrees0)
                try token.check()
                DispatchQueue.main.async {
                    guard let self,!self.closed,(try? token.check()) != nil else {return}
                    self.preview=result;self.working=false;self.committing=false
                    if commit {self.onApply(result,offset);self.window?.close()}
                }
            } catch {DispatchQueue.main.async {
                guard let self,!self.closed,(try? token.check()) != nil else {return}
                self.working=false;self.committing=false;self.error=error.localizedDescription
            }}
        }
    }
}

private struct LCCAlignmentView:View {
    @ObservedObject var model:LCCAlignmentModel
    @State private var dragOrigin:CGPoint?
    var body:some View {
        VStack(spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text(model.explanation == nil ? "手动对齐 LCC":"自动解算位置 · 结果预览").font(.title2.bold())
                    Text(model.explanation ?? "拖动预览中的标定覆盖范围，或调整下方位置。预览实时显示校正结果。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer();Toggle("显示标定边框",isOn:$model.showOutline).toggleStyle(.checkbox)
            }
            GeometryReader { geometry in
                let scale=min(geometry.size.width/model.base.size.width,geometry.size.height/model.base.size.height)
                let width=model.base.size.width*scale,height=model.base.size.height*scale
                ZStack {
                    Color(nsColor:.underPageBackgroundColor)
                    if let cg=model.preview.preview {PanoramaHDRPreview(image:cg).frame(width:width,height:height)}
                    if model.showOutline {
                        Canvas { context,size in
                            let mx=model.session.sensor.width/model.base.sources[0].size.width,my=model.session.sensor.height/model.base.sources[0].size.height
                            for r in model.preview.lccState?.footprintRects ?? [] {
                                let q=r.applying(CGAffineTransform(scaleX:scale,y:scale))
                                context.stroke(Path(q),with:.color(.cyan.opacity(0.25)),lineWidth:0.7)
                            }
                            if let r=model.preview.lccState?.suggestedCropRect {
                                context.stroke(Path(r.applying(CGAffineTransform(scaleX:scale,y:scale))),with:.color(.orange),style:StrokeStyle(lineWidth:1.5,dash:[6,4]))
                            }
                            let center=CGPoint(x:(model.base.size.width/2+model.x/mx)*scale,y:(model.base.size.height/2-model.y/my)*scale)
                            var cross=Path();cross.move(to:CGPoint(x:center.x-8,y:center.y));cross.addLine(to:CGPoint(x:center.x+8,y:center.y));cross.move(to:CGPoint(x:center.x,y:center.y-8));cross.addLine(to:CGPoint(x:center.x,y:center.y+8))
                            context.stroke(cross,with:.color(.cyan),lineWidth:2)
                        }.frame(width:width,height:height).clipped()
                    }
                    if model.working {VStack {Spacer();HStack {Spacer();ProgressView(model.committing ? "应用对齐…":"更新预览…").padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))}}.padding(10)}
                }.contentShape(Rectangle()).gesture(DragGesture().onChanged { value in
                    guard !model.committing else {return}
                    if dragOrigin==nil {dragOrigin=CGPoint(x:model.x,y:model.y)}
                    model.x=dragOrigin!.x+value.translation.width/scale*model.session.sensor.width/model.base.sources[0].size.width
                    model.y=dragOrigin!.y-value.translation.height/scale*model.session.sensor.height/model.base.sources[0].size.height
                }.onEnded {_ in dragOrigin=nil})
            }
            VStack(spacing:8) {
                HStack {Text("水平 X").frame(width:60);Slider(value:$model.x,in:-100...100);TextField("mm",value:$model.x,format:.number.precision(.fractionLength(2))).frame(width:85);Text("mm")}
                HStack {Text("垂直 Y").frame(width:60);Slider(value:$model.y,in:-100...100);TextField("mm",value:$model.y,format:.number.precision(.fractionLength(2))).frame(width:85);Text("mm")}
            }.textFieldStyle(.roundedBorder).disabled(model.committing)
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text(model.preview.lccState?.warning ?? "LCC 标定覆盖当前拼接范围。").font(.callout).foregroundStyle(model.preview.lccState?.complete == true ? Color.secondary:Color.orange)
                    Text("位置以拼接中心为基准，右／上为正。青色为标定范围；橙色虚线为可完整校正的裁切范围。预览使用固定白平衡。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer();Button("居中") {model.x=0;model.y=0}.disabled(model.committing)
                Button("取消") {model.window?.close()}.disabled(model.committing)
                Button("应用对齐") {model.render(commit:true)}.buttonStyle(.borderedProminent).disabled(model.working)
            }
        }.padding(18).onChange(of:model.x) {_,_ in model.schedule()}.onChange(of:model.y) {_,_ in model.schedule()}
        .alert("LCC 对齐",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {Button("好") {model.error=nil}} message: {Text(model.error ?? "")}
    }
}
