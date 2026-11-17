#if os(iOS)
import SwiftUI
import PhotonsLocalization

struct MobileGuideStep: Identifiable {
    let id: String
    let target: String
    let fallback: String?
    var title: String { L10n.tr("guide.\(id).title") }
    var detail: String { L10n.tr("guide.\(id).body") }
    init(_ id: String, target: String? = nil, fallback: String? = nil) {
        self.id = id; self.target = target ?? id; self.fallback = fallback
    }
}

@MainActor
final class MobileGuideController: ObservableObject {
    @Published private(set) var steps: [MobileGuideStep] = []
    @Published private(set) var index = 0
    @Published private(set) var frames: [String: CGRect] = [:]
    private var completion: (() -> Void)?
    var active: Bool { !steps.isEmpty }
    var step: MobileGuideStep? { steps.indices.contains(index) ? steps[index] : nil }
    func start(_ steps: [MobileGuideStep], completion: (() -> Void)? = nil) {
        self.completion = completion; index = 0; self.steps = steps
    }
    func next() { if index + 1 < steps.count { index += 1 } }
    func previous() { if index > 0 { index -= 1 } }
    func close() {
        let finished = completion
        completion = nil; steps = []; index = 0
        finished?()
    }
    func register(_ id: String, frame: CGRect) {
        guard frame.width.isFinite, frame.height.isFinite, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frames[id] != frame else { return }
        frames[id] = frame
    }
    func remove(_ id: String) { if frames[id] != nil { frames.removeValue(forKey: id) } }
    func highlight(in viewport: CGRect) -> CGRect? {
        guard let step else { return nil }
        for id in [step.target,step.fallback].compactMap({ $0 }) {
            guard let frame = frames[id] else { continue }
            let visible = frame.intersection(viewport)
            if !visible.isNull, visible.width > 2, visible.height > 2 {
                return visible.offsetBy(dx: -viewport.minX,dy: -viewport.minY)
            }
        }
        return nil
    }
}

/// Prefer space outside the highlighted control; clamp to the viewport on small windows.
enum MobileGuideLayout {
    static func cardArea(target: CGRect?, safe: CGRect) -> CGRect {
        guard let target else { return safe }
        let gap: CGFloat = 12
        let regions = [
            CGRect(x: safe.minX,y: safe.minY,width: max(0,target.minX-safe.minX-gap),height: safe.height),
            CGRect(x: max(safe.minX,target.maxX+gap),y: safe.minY,width: max(0,safe.maxX-target.maxX-gap),height: safe.height),
            CGRect(x: safe.minX,y: safe.minY,width: safe.width,height: max(0,target.minY-safe.minY-gap)),
            CGRect(x: safe.minX,y: max(safe.minY,target.maxY+gap),width: safe.width,height: max(0,safe.maxY-target.maxY-gap))
        ].map { $0.intersection(safe) }.filter {
            !$0.isNull && $0.width >= min(260,safe.width) && $0.height >= min(230,safe.height)
        }
        return regions.max { $0.width * $0.height < $1.width * $1.height } ?? safe
    }
}

extension View {
    @ViewBuilder
    func mobileGuideTarget(_ id: String, in guide: MobileGuideController?) -> some View {
        if let guide { mobileGuideTarget(id,in: guide) } else { self }
    }
    func mobileGuideTarget(_ id: String, in guide: MobileGuideController) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { guide.register(id,frame: $0) }
            .onDisappear { guide.remove(id) }
    }
    func mobileGuideOverlay(_ guide: MobileGuideController) -> some View {
        // Reserve a separate footer so Close never covers the real panorama Export button.
        // Padding also constrains NavigationStack's hosted content. An outer
        // safeAreaInset alone can leave its bottom export row behind the guide footer.
        padding(.bottom,guide.active ? 64 : 0)
        .accessibilityHidden(guide.active)
        .overlay { if guide.active { MobileGuideOverlay(guide: guide).ignoresSafeArea() } }
    }
}

struct MobileGuideButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("💡").font(.system(size: 20)).frame(width: 32,height: 32)
                .background(Color(white: 0.18),in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.3),lineWidth: 1))
                .frame(width: 44,height: 44)
        }.buttonStyle(.plain).accessibilityLabel(L10n.tr("guide.title"))
    }
}

private struct MobileGuideOverlay: View {
    @ObservedObject var guide: MobileGuideController
    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let highlight = guide.highlight(in: frame)
            let top = max(16,geometry.safeAreaInsets.top + 12)
            let bottom = max(24,geometry.safeAreaInsets.bottom + 12)
            let safe = CGRect(x: 16,y: top,width: max(1,geometry.size.width-32),height: max(1,geometry.size.height-top-bottom-64))
            let area = MobileGuideLayout.cardArea(target: highlight,safe: safe)
            ZStack {
                Color.clear.contentShape(Rectangle()).onTapGesture { }
                Path { path in
                    path.addRect(CGRect(origin: .zero,size: geometry.size))
                    if let highlight { path.addRoundedRect(in: highlight,cornerSize: CGSize(width: 8,height: 8)) }
                }.fill(.black.opacity(0.6),style: FillStyle(eoFill: true)).allowsHitTesting(false)
                if let highlight {
                    RoundedRectangle(cornerRadius: 8).stroke(.red,lineWidth: 3)
                        .frame(width: highlight.width,height: highlight.height)
                        .position(x: highlight.midX,y: highlight.midY).allowsHitTesting(false)
                        .accessibilityElement().accessibilityLabel(guide.step?.title ?? "")
                        .accessibilityIdentifier("guide-highlight")
                }
                if let step = guide.step {
                    VStack(alignment: .leading,spacing: 12) {
                        HStack {
                            Label(L10n.tr("guide.title"),systemImage: "lightbulb")
                            Spacer(); Text("\(guide.index+1) / \(guide.steps.count)").monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(step.title).font(.title3.weight(.semibold)).accessibilityIdentifier("guide-step-title")
                        ScrollView { Text(step.detail).frame(maxWidth: .infinity,alignment: .leading) }
                            .font(.body).accessibilityIdentifier("guide-step-detail")
                    }.padding(18).frame(width: min(400,area.width),height: min(260,area.height))
                        .background(Color(white: 0.12),in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.2)))
                        .position(x: area.midX,y: area.midY)
                }
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Button(L10n.tr("guide.previous"),action: guide.previous).disabled(guide.index == 0)
                            .accessibilityIdentifier("guide-previous")
                        Button(L10n.tr("guide.next"),action: guide.next).disabled(guide.index + 1 >= guide.steps.count)
                            .accessibilityIdentifier("guide-next")
                        Spacer()
                        Button(L10n.tr("guide.close"),action: guide.close).buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("guide-close")
                    }.buttonStyle(.bordered).padding(.horizontal,20).padding(.bottom,bottom)
                }
            }.foregroundStyle(.white).tint(.orange)
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("quick-guide")
            .accessibilityAction(.escape) { guide.close() }
    }
}

enum MobileGuideSteps {
    static let panoramaControlTargets: Set<String> = ["panorama.camera","panorama.positions","panorama.coordinates","panorama.guidance","panorama.perspective","panorama.alignment","panorama.solve","panorama.lcc"]
    static func panorama(shift: Bool) -> [MobileGuideStep] {
        var steps: [MobileGuideStep] = [.init("panorama.preview"),.init("panorama.histogram",fallback: "panorama.preview"),.init("panorama.hdr"),.init("panorama.controls")]
        steps += (shift ? ["camera","positions","coordinates","guidance"] : ["perspective"])
            .map { .init("panorama.\($0)",fallback: "panorama.controls") }
        steps += [.init("panorama.alignment",fallback: "panorama.controls"),.init("panorama.solve",fallback: "panorama.controls"),
                  .init(shift ? "panorama.lcc" : "panorama.perspectiveLCC",target: "panorama.lcc",fallback: "panorama.controls"),
                  .init("panorama.tone",fallback: "panorama.preview"),.init("panorama.export")]
        return steps
    }
    static func workspace(grid: Bool) -> [MobileGuideStep] {
        var steps: [MobileGuideStep] = [.init(grid ? "workspace.grid" : "workspace.canvas")]
        if !grid {
            steps += [.init("workspace.zoom",fallback: "workspace.canvas"),.init("workspace.navigation",fallback: "workspace.canvas")]
        }
        steps += ["library","gridMode","singleMode","help","import","hdr","panorama","tools","inspector","export","settings"]
            .map { .init("workspace.\($0)",fallback: "workspace.toolbar") }
        return steps
    }
}
#endif
