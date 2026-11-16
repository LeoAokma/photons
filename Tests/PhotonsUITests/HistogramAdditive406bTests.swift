import XCTest
import AppKit
import CoreGraphics
import PhotonsCore
import PhotonsUI

/// 406b — the additive layer must not hand **>1.0 components** to the compositor.
///
/// 403 built the overlap colour by adding three `plusLighter` series inside a transparency layer, and
/// that is right in the 8-bit sense: three full-coverage series clamp to white. What it did not settle
/// is what the layer *emits* on a surface that can hold more than white — an extended-range one, which
/// is what the window server composites for an EDR-capable display (this machine: 3.20 built-in, 4.08
/// external). `plusLighter` adds the *encoded components of the destination space*, and an sRGB primary
/// inside a Display P3 context is `(0.9176, 0.2003, 0.1386)` — three of those add to
/// `(1.3761, 1.1856, 1.3964)`. Clamped, that is white; kept, it normalises to `(0.985, 0.849, 1.000)`,
/// a pale magenta. That is the owner's pink.
///
/// So the measurement here has to be one an 8-bit bitmap physically cannot make: a **32-bit float
/// P3** context, read straight out of `CGContext.data` with no colour management and no clamp in the
/// way. `HistogramAdditive403Tests` samples through `NSBitmapImageRep.colorAt`, which is 8-bit and
/// therefore blind to this whole class of bug (as its own numbers showed).
///
/// The four cases below are 403's ①–③ restated at a threshold that only holds if the layer never
/// leaves `0…1`: `≥ 0.999` / `≤ 0.001`, not the `0.85` an 8-bit dither needs.
@MainActor
final class HistogramAdditive406bTests: XCTestCase {

    private let cardWidth: CGFloat = 400
    private let scale: CGFloat = 2
    private let cardHeight = HistogramCardView.contentHeight

    /// 403's fixture geometry, unchanged: a five-bin plateau clear of the quarter-tone guides.
    private let plateau = 100...104
    private let sampleBin = 102

    // MARK: - fixtures

    private func histogram(red: Int = 0, green: Int = 0, blue: Int = 0, luma: Int = 0,
                           headroom: Double = 1) -> Histogram {
        func channel(_ value: Int) -> HistogramChannel {
            HistogramChannel(bins: (0..<256).map { plateau.contains($0) ? value : 0 },
                             hdrBins: [Int](repeating: 0, count: Histogram.hdrBinCount),
                             clippedHigh: 0, clippedCeiling: 0, clippedLow: 0)
        }
        return Histogram(binCount: 256, sampleCount: 898_432,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: headroom,
                         red: channel(red), green: channel(green), blue: channel(blue),
                         luma: channel(luma))
    }

    // MARK: - the extended-range surface

    /// A `CGContext` that can hold more than white: 32 bits per component, float, premultiplied alpha,
    /// **Display P3** — the space this machine's screens actually work in.
    ///
    /// Built with CoreGraphics rather than `NSBitmapImageRep` on purpose: `NSColorSpaceName` has no
    /// `.displayP3` member, and going through `NSBitmapImageRep` would put its own conversion and its
    /// own storage format between the drawing and the read.
    private func floatContext(width: Int, height: Int) -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue
                                | CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 32,
                         bytesPerRow: width * 4 * MemoryLayout<Float32>.size,
                         space: space, bitmapInfo: info.rawValue)!
    }

    /// One real `draw` into the float P3 surface, at 2×, appearance pinned.
    private func floatBitmap(of histogram: Histogram?,
                             appearance: NSAppearance.Name = .aqua) -> CGContext {
        let ctx = floatContext(width: Int(cardWidth * scale), height: Int(cardHeight * scale))
        // Start from opaque black rather than transparent: then every read below is a *painted*
        // value, and a pixel the card never touches cannot look like a channel that came out at 0.
        ctx.setFillColor(CGColor(colorSpace: ctx.colorSpace!,
                                 components: [0, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(ctx.width), height: CGFloat(ctx.height)))
        // A raw `CGContext` carries no rep and therefore no scale: 403 got its 2× from
        // `NSBitmapImageRep.size`, which `NSGraphicsContext` honours. Without this the card would draw
        // into the bottom-left quarter only — measured, not assumed.
        ctx.scaleBy(x: scale, y: scale)

        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        let resolution = NSAppearance(named: appearance)!
        card.appearance = resolution
        card.histogram = histogram
        lastCard = card

        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        resolution.performAsCurrentDrawingAppearance {
            card.draw(card.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx
    }

    private var lastCard: HistogramCardView?

    /// Unmanaged components of one pixel: **no** `colorAt`, no colour management, no clamp.
    ///
    /// The context allocates its floats big-endian (measured: a `0.25` written by CoreGraphics lands as
    /// `3e 80 00 00`), so they are byte-swapped back before being read as `Float32`.
    private func components(_ ctx: CGContext, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let p = ctx.data! + y * ctx.bytesPerRow + x * 4 * MemoryLayout<Float32>.size
        let words = p.withMemoryRebound(to: UInt32.self, capacity: 4) { $0 }
        func value(_ i: Int) -> Double {
            Double(Float(bitPattern: UInt32(bigEndian: words[i])))
        }
        return (value(0), value(1), value(2))
    }

    /// The card is `isFlipped`, and AppKit flips the view into a non-flipped context, so a view point
    /// `y` lands on bitmap row `(cardHeight − y) × scale` — 403's measured mapping, reused.
    private func row(forViewY y: CGFloat) -> Int {
        Int(((cardHeight - y) * scale).rounded())
    }

    /// The bitmap column of the fixture's bin, and **every** row of the plot band (the plateau is a
    /// full-height column, so the whole band is the same colour — no single row can flatter the result).
    private func plotRows(_ card: HistogramCardView) -> (x: Int, rows: Range<Int>) {
        let axis = card.lastAxis!
        let x = Int((axis.x(sdrBin: sampleBin, of: 256) * scale).rounded())
        let plot = axis.plot
        return (x, row(forViewY: plot.maxY)..<row(forViewY: plot.minY))
    }

    private func formatted(_ c: (r: Double, g: Double, b: Double)) -> String {
        String(format: "(r %.4f, g %.4f, b %.4f)", c.r, c.g, c.b)
    }

    // MARK: - ① the layer never emits more than white

    /// The core case, and the one that was red before the fix.
    ///
    /// Every pixel of the whole card, not just the plateau: the defect lives in what the transparency
    /// layer hands out, so a sample that misses the overlap would miss it too. The three-way overlap is
    /// the worst case (all three sums peak there), so it is printed separately for the record.
    func testTheAdditiveLayerNeverEmitsMoreThanOne() {
        let ctx = floatBitmap(of: histogram(red: 1000, green: 1000, blue: 1000))
        let card = lastCard!
        let (x, rows) = plotRows(card)

        var worst = (r: 0.0, g: 0.0, b: 0.0)
        var worstAt = (x: 0, y: 0)
        var overOne = 0
        for py in 0..<ctx.height {
            for px in 0..<ctx.width {
                let c = components(ctx, x: px, y: py)
                for v in [c.r, c.g, c.b] where v > 1.0 + 1e-6 { overOne += 1; break }
                if max(c.r, c.g, c.b) > max(worst.r, worst.g, worst.b) {
                    worst = c
                    worstAt = (px, py)
                }
            }
        }

        // The whole plateau column, printed as [min, max] per component: a single row could be an
        // antialiased edge and would understate the overflow.
        var lo = (r: Double.infinity, g: Double.infinity, b: Double.infinity)
        var hi = (r: -Double.infinity, g: -Double.infinity, b: -Double.infinity)
        for py in rows {
            let c = components(ctx, x: x, y: py)
            lo = (min(lo.r, c.r), min(lo.g, c.g), min(lo.b, c.b))
            hi = (max(hi.r, c.r), max(hi.g, c.g), max(hi.b, c.b))
        }
        print("① 32-bit float P3 · 整卡最亮像素 @(\(worstAt.x), \(worstAt.y)) → \(formatted(worst))")
        print("① R+G+B 列 x=\(x) 沿 plot 的 min \(formatted(lo)) · max \(formatted(hi))")
        print("① 分量 > 1.0 的像素数：\(overOne)（改前应为非零，改后 0）")

        XCTAssertEqual(overOne, 0, "加色层不许交出 > 1.0 的分量：最亮处 \(formatted(worst))")
        XCTAssertLessThanOrEqual(hi.r, 1.0 + 1e-6, "R 分量超出 SDR：\(formatted(hi))")
        XCTAssertLessThanOrEqual(hi.g, 1.0 + 1e-6, "G 分量超出 SDR：\(formatted(hi))")
        XCTAssertLessThanOrEqual(hi.b, 1.0 + 1e-6, "B 分量超出 SDR：\(formatted(hi))")
    }

    // MARK: - ② three full series are exactly white

    /// 403's ③ at a threshold that means "exactly": every component of the overlap column is 1.0, and
    /// the three of them agree. In the encoded P3 domain the sum has to *be* white, not merely clamp
    /// to something that looks white once it is squeezed into 8 bits.
    func testThreeWayOverlapIsExactlyWhite() {
        let ctx = floatBitmap(of: histogram(red: 1000, green: 1000, blue: 1000))
        let card = lastCard!
        let (x, rows) = plotRows(card)
        var worst = (r: Double.infinity, g: Double.infinity, b: Double.infinity)
        for py in rows {
            let c = components(ctx, x: x, y: py)
            worst = (min(worst.r, c.r), min(worst.g, c.g), min(worst.b, c.b))
        }
        print("② 三路齐满 · x=\(x) 沿 plot 的逐分量最小值 → \(formatted(worst))")
        XCTAssertGreaterThanOrEqual(min(worst.r, worst.g, worst.b), 0.999,
                                   "三路齐必须正好是白，实测 \(formatted(worst))")
        XCTAssertLessThanOrEqual(max(worst.r, worst.g, worst.b)
                                 - min(worst.r, worst.g, worst.b), 0.001,
                                 "白是中性：三分量必须相等，实测 \(formatted(worst))")
    }

    // MARK: - ③ R + G is exactly yellow

    func testRedPlusGreenIsExactlyYellow() {
        let ctx = floatBitmap(of: histogram(red: 1000, green: 1000))
        let card = lastCard!
        let (x, rows) = plotRows(card)
        var worst = (r: Double.infinity, g: Double.infinity, b: -Double.infinity)
        for py in rows {
            let c = components(ctx, x: x, y: py)
            worst = (min(worst.r, c.r), min(worst.g, c.g), max(worst.b, c.b))
        }
        print("③ R+G · x=\(x) 沿 plot 的 (min r, min g, max b) → \(formatted((worst.r, worst.g, worst.b)))")
        XCTAssertGreaterThanOrEqual(min(worst.r, worst.g), 0.999,
                                    "R+G 的黄：r 与 g 都必须是满的，实测 \(formatted((worst.r, worst.g, worst.b)))")
        XCTAssertLessThanOrEqual(worst.b, 0.001,
                                 "R+G 的蓝必须是零：红绿相加不该带出蓝，实测 \(formatted((worst.r, worst.g, worst.b)))")
    }

    // MARK: - ④ a single series is exactly its own primary

    func testSingleChannelIsExactlyItsOwnPrimary() {
        let cases: [(name: String, histogram: Histogram, on: Int)] = [
            ("单 R", histogram(red: 1000), 0),
            ("单 G", histogram(green: 1000), 1),
            ("单 B", histogram(blue: 1000), 2),
        ]
        for c in cases {
            let ctx = floatBitmap(of: c.histogram)
            let card = lastCard!
            let (x, rows) = plotRows(card)
            var lo = (r: Double.infinity, g: Double.infinity, b: Double.infinity)
            for py in rows {
                let p = components(ctx, x: x, y: py)
                lo = (min(lo.r, p.r), min(lo.g, p.g), min(lo.b, p.b))
            }
            let v = [lo.r, lo.g, lo.b]
            print("④ \(c.name) · x=\(x) 沿 plot 的逐分量最小值 → \(formatted(lo))")
            XCTAssertGreaterThanOrEqual(v[c.on], 0.999, "\(c.name)：自己的那一路必须是满的，实测 \(formatted(lo))")
            for i in 0..<3 where i != c.on {
                XCTAssertLessThanOrEqual(v[i], 0.001,
                                         "\(c.name)：第 \(i) 路必须是零，实测 \(formatted(lo))")
            }
        }
    }
}
