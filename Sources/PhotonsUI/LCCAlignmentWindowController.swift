import PhotonsLocalization
import AppKit
import SwiftUI
import PhotonsPanorama

// Immutable session snapshots are shared with the serial preview worker.
final class LCCEditingSession: @unchecked Sendable {
    let profile:LCCLensProfile
    let fields:[LCCCaptureOrientation:LCCCorrectionField]
    let sensor:SensorSize
    let preparedPlan:PanoramaPlan
    init(plan:PanoramaPlan,profile:LCCLensProfile,sensor:SensorSize,engine:PanoramaEngine,token:PanoramaCancellation,progress:@escaping PanoramaEngine.Progress) throws {
        self.profile=profile;self.sensor=sensor
        var fields:[LCCCaptureOrientation:LCCCorrectionField]=[:]
        for orientation in profile.orientations {
            try token.check();progress(L10n.tr("7ef05e0d7696" , String(describing: (orientation.title))))
            fields[orientation]=try LCCCorrectionField(profile:profile,orientation:orientation,cancellation:token)
        }
        self.fields=fields
        preparedPlan=try engine.prepareLCCImages(plan,cancellation:token,progress:progress)
    }
}

@MainActor
final class LCCAlignmentWindowController:NSWindowController,NSWindowDelegate {
    let model:LCCAlignmentModel
    var onClose:(()->Void)?
    init(model: LCCAlignmentModel) {
        self.model = model
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:800),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title=L10n.tr("3a579ac6686e");w.minSize=NSSize(width:900,height:650);w.isReleasedWhenClosed=false
        super.init(window:w);w.delegate=self;model.window=w
        w.contentView=NSHostingView(rootView:LCCAlignmentView(model:model));w.center();model.schedule()
    }
    required init?(coder:NSCoder) {fatalError("no nib")}
    func windowWillClose(_ notification:Notification) {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        model.close()
        onClose?()
    }
}

@MainActor
final class LCCAlignmentModel: ObservableObject {
    weak var window: NSWindow?
    let base: PanoramaPlan
    let sensor: SensorSize
    let explanation: String?
    @Published var x: Double { didSet { if x != oldValue { schedule() } } }
    @Published var y: Double { didSet { if y != oldValue { schedule() } } }
    @Published private(set) var preview: PanoramaPlan
    @Published private(set) var working = false
    @Published var showOutline = true
    @Published var error: String?
    private let renderPreview: (CGPoint, PanoramaCancellation) throws -> PanoramaPlan
    private let onApply: (PanoramaPlan) -> Void
    private let queue = DispatchQueue(label: "Photons.lcc.alignment", qos: .userInitiated)
    private var token = PanoramaCancellation()
    private var readyOffset: CGPoint?
    private var closed = false

    init(plan: PanoramaPlan, sensor: SensorSize, offset: CGPoint, explanation: String?,
         renderPreview: @escaping (CGPoint, PanoramaCancellation) throws -> PanoramaPlan,
         onApply: @escaping (PanoramaPlan) -> Void) {
        base = plan
        preview = plan
        self.sensor = sensor
        x = offset.x
        y = offset.y
        self.explanation = explanation
        self.renderPreview = renderPreview
        self.onApply = onApply
    }

    func close() {
        closed = true
        token.cancel()
    }

    var canApply: Bool { !closed && !working && readyOffset == CGPoint(x: x, y: y) }

    func apply() {
        window?.makeFirstResponder(nil)
        guard canApply else { return }
        close()
        onApply(preview)
        window?.close()
    }

    func schedule() {
        guard !closed else { return }
        token.cancel()
        token = PanoramaCancellation()
        let token = self.token, offset = CGPoint(x: x, y: y), render = renderPreview
        readyOffset = nil
        guard x.isFinite, y.isFinite else {
            working = false
            error = L10n.tr("d235647a10ab")
            return
        }
        error = nil
        working = true
        queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            let outcome = Result {
                try token.check()
                let plan = try render(offset, token)
                guard plan.preview != nil else { throw PanoramaFailure(L10n.tr("ipad.9d1d128ebb9f")) }
                return plan
            }
            DispatchQueue.main.async {
                guard let self, !self.closed, self.token === token else { return }
                switch outcome {
                case .success(let plan):
                    self.preview = plan
                    self.readyOffset = offset
                case .failure(let error):
                    self.error = error.localizedDescription
                }
                self.working = false
            }
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
                    Text(model.explanation == nil ? L10n.tr("3a579ac6686e"):L10n.tr("88cedbfbe0da")).font(.title2.bold())
                    Text(model.explanation ?? L10n.tr("5bb313b69db4")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer();Toggle(L10n.tr("e33473ee7de8"),isOn:$model.showOutline).toggleStyle(.checkbox)
            }
            GeometryReader { geometry in
                let scale=min(geometry.size.width/model.base.size.width,geometry.size.height/model.base.size.height)
                let width=model.base.size.width*scale,height=model.base.size.height*scale
                ZStack {
                    Color(nsColor:.underPageBackgroundColor)
                    if let cg = model.preview.preview {
                        let crop = model.preview.lccState?.cropRect ?? CGRect(origin: .zero, size: model.base.size)
                        PanoramaHDRPreview(image: cg)
                            .frame(width: crop.width * scale, height: crop.height * scale)
                            .offset(x: (crop.midX - model.base.size.width / 2) * scale,
                                    y: (crop.midY - model.base.size.height / 2) * scale)
                    }
                    if model.showOutline {
                        Canvas { context,size in
                            let mx=model.sensor.width/model.base.sources[0].size.width,my=model.sensor.height/model.base.sources[0].size.height
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
                }.contentShape(Rectangle()).gesture(DragGesture().onChanged { value in
                    if dragOrigin==nil {dragOrigin=CGPoint(x:model.x,y:model.y)}
                    model.x=dragOrigin!.x+value.translation.width/scale*model.sensor.width/model.base.sources[0].size.width
                    model.y=dragOrigin!.y-value.translation.height/scale*model.sensor.height/model.base.sources[0].size.height
                }.onEnded {_ in dragOrigin=nil})
                .overlay(alignment: .top) {
                    if model.working {
                        ProgressView(L10n.tr("0cd2df38d720")).controlSize(.small).padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(10).allowsHitTesting(false)
                    }
                }
                .overlay {
                    // On very narrow or shallow panoramas the controls can use the letterbox.
                    let controlWidth = min(geometry.size.width, max(width, 400))
                    let controlHeight = min(geometry.size.height, max(height, 250))
                    Color.clear.allowsHitTesting(false)
                        .frame(width: controlWidth, height: controlHeight)
                        .overlay(alignment: .bottom) {
                            positionControl(.horizontal, length: min(230, controlWidth * 0.31))
                                .padding(.bottom, 10)
                        }
                        .overlay(alignment: .trailing) {
                            positionControl(.vertical, length: min(160, controlHeight * 0.32))
                                .padding(.trailing, 10)
                        }
                }
            }
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text(model.preview.lccState?.warning ?? L10n.tr("7aeb211ca8bb")).font(.callout).foregroundStyle(model.preview.lccState?.complete == true ? Color.secondary:Color.orange)
                    Text(L10n.tr("8c1e47e38eb8")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer();Button(L10n.tr("4cc3885c182e")) {model.x=0;model.y=0}
                Button(L10n.tr("2cd0f3be8738")) {model.window?.close()}
                Button(L10n.tr("c5160c4ce0c4")) {model.apply()}.buttonStyle(.borderedProminent).disabled(!model.canApply)
            }
        }.padding(18)
        .alert(L10n.tr("5836a4495ac1"),isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {Button(L10n.tr("f867f3417859")) {model.error=nil}} message: {Text(model.error ?? "")}
    }

    private func positionControl(_ axis: Axis, length: CGFloat) -> some View {
        let horizontal = axis == .horizontal
        let value = horizontal ? $model.x : $model.y
        let reset = { value.wrappedValue = 0 }
        let name = L10n.tr(horizontal ? "98ab61de3e93" : "5e9009b476b1")
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 6))
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return layout {
            Text(verbatim: horizontal ? "X (mm)" : "Y (mm)").font(.caption.weight(.medium))
                .modifier(ResetOnDoubleClick(action: reset))
            AdjustmentSlider(value: value, in: -100...100, axis: axis, onReset: reset)
                .frame(width: horizontal ? length : nil, height: horizontal ? nil : length)
                .accessibilityLabel(name)
            TextField(name, value: value, format: .number.precision(.fractionLength(2)))
                .labelsHidden().textFieldStyle(.roundedBorder).controlSize(.small)
                .multilineTextAlignment(.center).monospacedDigit().frame(width: 56)
        }
        .padding(.horizontal, horizontal ? 10 : 7).padding(.vertical, horizontal ? 6 : 8)
        .background(.ultraThinMaterial, in: shape)
        .overlay { shape.strokeBorder(.primary.opacity(0.16)).allowsHitTesting(false) }
    }
}
