import AppKit
import SwiftUI
import CoreImage
import PhotonsCore

/// The same half-float Metal surface used by the grid and loupe placeholder, fitted to
/// the entire panorama. SwiftUI's ordinary Image would flatten this into an SDR layer.
struct PanoramaHDRPreview: View {
    let image: CGImage
    @State private var headroom = DisplayHeadroom.sdr

    var body: some View {
        PanoramaHDRSurface(image: image) { headroom = $0 }
            .overlay(alignment: .bottomLeading) {
                Text("HDR 预览 · \(headroom.displayText)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8).allowsHitTesting(false)
            }
            .allowsHitTesting(false)
    }
}

private struct PanoramaHDRSurface: NSViewRepresentable {
    let image: CGImage
    let onHeadroom: (DisplayHeadroom) -> Void
    func makeNSView(context: Context) -> PanoramaHDRPreviewView { PanoramaHDRPreviewView() }
    func updateNSView(_ view: PanoramaHDRPreviewView, context: Context) {
        view.onHeadroom = onHeadroom
        view.setImage(image)
    }
}

@MainActor
final class PanoramaHDRPreviewView: NSView {
    let surface = ThumbnailEDRView(cornerRadius: 0)
    private var source: CGImage?
    private var timer: Timer?
    private var headroom: DisplayHeadroom?
    var onHeadroom: ((DisplayHeadroom) -> Void)?
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init() {
        super.init(frame: .zero)
        addSubview(surface)
    }
    required init?(coder: NSCoder) { fatalError("no nib") }
    deinit { timer?.invalidate() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
        let scale = min(bounds.width / CGFloat(source.width), bounds.height / CGFloat(source.height))
        let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        surface.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height)
        surface.needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        updateHeadroom()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHeadroom() }
        }
    }

    private func updateHeadroom() {
        let value = DisplayHeadroom.current(for: window?.screen,
            layerAcceptsEDR: ThumbnailMetalRenderer.shared.isAvailable)
        guard value != headroom else { return }
        headroom = value
        DispatchQueue.main.async { [weak self] in self?.onHeadroom?(value) }
    }
}
