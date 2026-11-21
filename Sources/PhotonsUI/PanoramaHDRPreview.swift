import PhotonsLocalization
import AppKit
import SwiftUI
import CoreImage
import PhotonsCore

/// The same half-float Metal surface used by the grid and loupe placeholder, fitted to
/// the entire panorama. SwiftUI's ordinary Image would flatten this into an SDR layer.
struct PanoramaHDRPreview: View {
    let image: CGImage
    var outputPixels: CGSize? = nil
    @State private var zoom = PanoramaPreviewZoom()
    @AppStorage(DoubleClickZoom.key) private var savedTarget = 1.0
    @State private var headroom = DisplayHeadroom.sdr
    @Bindable private var preferences=ApplicationPreferences.shared

    var body: some View {
        PanoramaHDRSurface(image: image, outputPixels: outputPixels, zoom: $zoom) { headroom = $0 }
            .allowsHitTesting(outputPixels != nil)
            .onChange(of: outputPixels) { zoom = PanoramaPreviewZoom() }
            .overlay(alignment: .topLeading) {
                Button(preferences.hdrPreview ? "HDR":"SDR") {preferences.hdrPreview.toggle()}
                    .buttonStyle(.bordered).padding(12)
                    .help(L10n.tr("1241282e23af"))
                    .accessibilityIdentifier("panorama.dynamicRange")
            }
            .overlay(alignment: .topTrailing) {
                PanoramaPreviewHistogram(image:image,hdr:preferences.hdrPreview,headroom:headroom.headroom)
                    .equatable()
                    .frame(width:230,height:HistogramCardView.contentHeight).padding(6)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                Text(preferences.hdrPreview ? L10n.tr("eb1c4475f146" , String(describing: (headroom.displayText))):L10n.tr("2e895f4004e4"))
                    .font(.caption).foregroundStyle(.secondary).padding(7)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:6)).padding(8).allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if outputPixels != nil {
                    VStack(alignment: .trailing, spacing: 4) {
                        if zoom.scale != nil {
                            Text(L10n.tr("panorama.preview.lowResolution"))
                                .font(.caption2).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule()).allowsHitTesting(false)
                        }
                        zoomControls
                    }
                    .fixedSize().padding(8)
                }
            }
    }

    private var zoomControls: some View {
        let fit = L10n.tr("53c9aca4b68c")
        let target = LoupeViewState.percentLabel(of: PhotoZoomTarget.range.contains(savedTarget) ? savedTarget : 1)
        return HStack(spacing: 8) {
            if let scale = zoom.scale {
                Text(LoupeViewState.percentLabel(of: scale)).monospacedDigit()
                Button(fit) { zoom = PanoramaPreviewZoom() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("panorama.zoom.fit")
            } else {
                Text(fit)
            }
            Divider().frame(height: 12)
            Menu {
                ForEach(PhotoZoomTarget.presets, id: \.self) { scale in
                    Button(LoupeViewState.percentLabel(of: scale)) { choose(scale) }
                }
                Button(L10n.tr("ipad.c4e69d543a44")) {
                    if let scale = DoubleClickZoom.askForCustomTarget() { choose(scale) }
                }
            } label: {
                Label(target, systemImage: "plus.magnifyingglass").monospacedDigit()
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .help(L10n.tr("zoom.doubleClickTarget"))
            .accessibilityLabel(L10n.tr("zoom.doubleClickTarget"))
            .accessibilityValue(target)
            .accessibilityIdentifier("panorama.zoom.target")
        }
        .font(.caption.weight(.medium)).controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.16), lineWidth: 0.5).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panorama.zoom.controls")
    }

    private func choose(_ target: Double) {
        DoubleClickZoom.target = target
        if zoom.scale != nil { zoom.scale = target }
    }
}

private struct PanoramaHDRSurface: NSViewRepresentable {
    let image: CGImage
    let outputPixels: CGSize?
    @Binding var zoom: PanoramaPreviewZoom
    let onHeadroom: (DisplayHeadroom) -> Void
    func makeNSView(context: Context) -> PanoramaHDRPreviewView { PanoramaHDRPreviewView() }
    func updateNSView(_ view: PanoramaHDRPreviewView, context: Context) {
        view.onHeadroom = onHeadroom
        view.outputPixels = outputPixels
        view.zoom = zoom
        view.onZoom = { zoom = $0 }
        view.setImage(image)
    }
}

@MainActor
final class PanoramaHDRPreviewView: NSView {
    let surface = ThumbnailEDRView(cornerRadius: 0)
    var outputPixels: CGSize? { didSet { if oldValue != outputPixels { needsLayout = true } } }
    var zoom = PanoramaPreviewZoom() { didSet { if oldValue != zoom { needsLayout = true } } }
    var onZoom: ((PanoramaPreviewZoom) -> Void)?
    private var photoGestures: PhotoCanvasGestures?
    private var source: CGImage?
    private var timer: Timer?
    private var headroom: DisplayHeadroom?
    private var preferencesObserver: NSObjectProtocol?
    var onHeadroom: ((DisplayHeadroom) -> Void)?
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init() {
        super.init(frame: .zero)
        addSubview(surface)
        photoGestures = PhotoCanvasGestures(view: self, onPinch: { [weak self] factor, point in
            guard let self, let pixels = interactivePixels else { return }
            let scale = zoom.scale ?? zoom.fit(pixels, in: bounds.size, backing: backing)
            applyScale(scale * factor, at: point)
        }, onDoubleTap: { [weak self] point in self?.toggleZoom(at: point) })
        let drag = NSPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.delaysPrimaryMouseButtonEvents = false
        drag.allowedTouchTypes = .direct
        if #available(macOS 27.0, *) { drag.maximumNumberOfTouches = 1 }
        addGestureRecognizer(drag)
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .photonsPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.updateHeadroom()
            }
    }
    required init?(coder: NSCoder) { fatalError("no nib") }
    deinit {
        timer?.invalidate()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }
    override var isFlipped: Bool { true }
    private var backing: CGFloat { window?.backingScaleFactor ?? 1 }
    private var interactivePixels: CGSize? {
        guard let size = outputPixels, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        return size
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard outputPixels != nil, super.hitTest(point) != nil else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { outputPixels != nil }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount > 0 && event.clickCount.isMultiple(of: 2) {
            toggleZoom(at: convert(event.locationInWindow, from: nil))
        }
    }

    func toggleZoom(at point: CGPoint) {
        if zoom.scale == nil { applyScale(DoubleClickZoom.target, at: point) }
        else { zoom = PanoramaPreviewZoom(); onZoom?(zoom) }
    }

    func applyScale(_ scale: CGFloat, at point: CGPoint) {
        guard let pixels = interactivePixels else { return }
        zoom.magnify(to: scale, at: point, pixels: pixels, in: bounds.size, backing: backing)
        onZoom?(zoom)
    }

    @objc private func dragged(_ drag: NSPanGestureRecognizer) {
        let delta = drag.translation(in: self)
        drag.setTranslation(.zero, in: self)
        pan(by: delta)
    }

    private func pan(by delta: CGPoint) {
        guard let pixels = interactivePixels, zoom.scale != nil else { return }
        zoom.pan(by: delta, pixels: pixels, in: bounds.size, backing: backing)
        onZoom?(zoom)
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom.scale != nil else { super.scrollWheel(with: event); return }
        pan(by: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    func setImage(_ image: CGImage) {
        guard source !== image else { return }
        source = image
        let space = CanvasPresenter.Storage.linear16.colorSpace!
        if ThumbnailMetalRenderer.shared.isAvailable,
           image.bitsPerComponent == 16, image.bitmapInfo.contains(.floatComponents),
           image.colorSpace == space {
            surface.image = image
        } else {
            // ThumbnailMetalSurface's fast upload assumes half-float P3. Convert, do not
            // merely retag, if a future producer supplies another working colour space.
            let ci = CIImage(cgImage: image)
            let metal = ThumbnailMetalRenderer.shared.isAvailable
            surface.image = Self.context.createCGImage(ci, from: ci.extent,
                format: metal ? .RGBAh : .RGBA8,
                colorSpace: metal ? space : CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let source else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let pixels = interactivePixels ?? CGSize(width: source.width, height: source.height)
        let frame = zoom.imageFrame(pixels, in: bounds.size, backing: backing)
        let visible = frame.intersection(bounds)
        surface.frame = visible
        // Sample the visible region of the preview. Its Metal drawable stays within the window,
        // even when 800% would make the complete stitch hundreds of thousands of pixels wide.
        surface.sourceWindow = zoom.scale == nil ? nil : CGRect(
            x: (visible.minX - frame.minX) / frame.width, y: (visible.minY - frame.minY) / frame.height,
            width: visible.width / frame.width, height: visible.height / frame.height)
        surface.needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        updateHeadroom()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                self.updateHeadroom()
            }
        }
        timer?.tolerance = 0.2
    }

    private func updateHeadroom() {
        let value = DisplayHeadroom.current(for: window?.screen,
            layerAcceptsEDR: ThumbnailMetalRenderer.shared.isAvailable && ProcessingPreferences.hdrPreview)
        guard value != headroom else { return }
        headroom = value
        DispatchQueue.main.async { [weak self] in self?.onHeadroom?(value) }
    }
}

/// Bounded preview sampling: changing exposure or proof mode updates the same plot as the editor.
private struct PanoramaPreviewHistogram:NSViewRepresentable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.image === rhs.image && lhs.hdr == rhs.hdr && lhs.headroom == rhs.headroom
    }

    let image:CGImage
    let hdr:Bool
    let headroom:Double
    func makeNSView(context:Context)->HistogramCardView {HistogramCardView()}
    func updateNSView(_ view:HistogramCardView,context:Context) {
        if context.coordinator.source !== image {
            let w=128,h=max(1,Int(Double(w)*Double(image.height)/Double(image.width)))
            let space=CGColorSpace(name:CGColorSpace.extendedLinearITUR_2020)!
            let ci=CIImage(cgImage:image).transformed(by:CGAffineTransform(scaleX:Double(w)/Double(image.width),y:Double(h)/Double(image.height)))
            var pixels=[Float16](repeating:0,count:w*h*4)
            Self.context.render(ci,toBitmap:&pixels,rowBytes:w*8,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAh,colorSpace:space)
            context.coordinator.sample=LinearSample(width:w,height:h,rgba:pixels)
            context.coordinator.source=image
        }
        if let sample=context.coordinator.sample {
            view.histogram=hdr ? Histogram.compute(sample,headroom:headroom):SDRProjection.histogram(sample,bins:256,rect:nil,primaries:.displayP3)
        }
        view.needsDisplay=true
    }
    private static let context=CIContext(options:[.cacheIntermediates:false])
    final class Coordinator {var source:CGImage?;var sample:LinearSample?}
    func makeCoordinator()->Coordinator {Coordinator()}
}
