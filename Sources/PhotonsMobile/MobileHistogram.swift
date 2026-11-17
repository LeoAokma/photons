#if os(iOS)
import SwiftUI
import UIKit
import PhotonsCore

/// Same code/tail split and linear, endpoint-resistant peak rule as the Mac HistogramPlot.
enum MobileHistogramReading {
    static func bin(at fraction: Double,hdr: Bool) -> (tail: Bool,index: Int) {
        let u = min(1,max(0,fraction.isFinite ? fraction : 0))
        if hdr && u >= 0.5 { return (true,min(255,Int((u-0.5)*512))) }
        return (false,min(255,Int(u*(hdr ? 512 : 256))))
    }
    static func peak(_ channel: HistogramChannel) -> Int {
        let values = channel.bins + channel.hdrBins
        let interior = values.dropFirst().dropLast().max() ?? 0
        return max(1,interior > 0 ? interior : (values.max() ?? 0))
    }
    static func percent(_ value: Double) -> String {
        if value > 0 && value < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%",value*100)
    }
}
struct MobileHistogram: View {
    let histogram: Histogram
    var hdr = true
    @State private var headroom = 1.0
    @State private var pointer: Double?
    private var measured: Histogram { histogram.withDisplayHeadroom(hdr ? headroom : 1) }
    var body: some View {
        VStack(alignment: .leading,spacing: 7) {
            HStack {
                Text(hdr ? "HDR · Rec.2020" : "SDR · Display P3").font(.caption.weight(.semibold))
                Spacer()
                Text("\(histogram.canvas.width) × \(histogram.canvas.height)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Canvas { context,size in
                    let split = hdr ? size.width/2 : size.width
                    context.fill(Path(CGRect(origin: .zero,size: size)),with: .color(.black))
                    if hdr { context.fill(Path(CGRect(x: split,y: 0,width: split,height: size.height)),with: .color(Color(white: 0.07))) }
                    let colors: [Color] = [.init(.sRGB,red: 1,green: 0,blue: 0,opacity: 1),.init(.sRGB,red: 0,green: 1,blue: 0,opacity: 1),.init(.sRGB,red: 0,green: 0,blue: 1,opacity: 1)]
                    var rgb = context; rgb.blendMode = .plusLighter
                    for (index,channel) in [histogram.red,histogram.green,histogram.blue].enumerated() {
                        let peak = Double(MobileHistogramReading.peak(channel))
                        var path = Path(); path.move(to: CGPoint(x: 0,y: size.height))
                        for (i,count) in channel.bins.enumerated() {
                            path.addLine(to: CGPoint(x: (Double(i)+0.5)/Double(max(1,channel.bins.count))*split,
                                y: size.height*(1-min(1,Double(count)/peak))))
                        }
                        if hdr {
                            for (i,count) in channel.hdrBins.enumerated() {
                                path.addLine(to: CGPoint(x: split+(Double(i)+0.5)/Double(max(1,channel.hdrBins.count))*split,
                                    y: size.height*(1-min(1,Double(count)/peak))))
                            }
                        }
                        path.addLine(to: CGPoint(x: size.width,y: size.height)); path.closeSubpath()
                        rgb.fill(path,with: .color(colors[index]))
                    }
                    for i in 1...4 {
                        var line = Path(); let x = split*Double(i)/4
                        line.move(to: CGPoint(x: x,y: 0)); line.addLine(to: CGPoint(x: x,y: size.height))
                        if hdr { line.move(to: CGPoint(x: split+x,y: 0)); line.addLine(to: CGPoint(x: split+x,y: size.height)) }
                        context.stroke(line,with: .color(.white.opacity(0.2)),lineWidth: 0.5)
                    }
                    if hdr {
                        let x = split + split * min(4,max(0,log2(max(1,headroom))))/4
                        var ceiling = Path(); ceiling.move(to: CGPoint(x: x,y: 0)); ceiling.addLine(to: CGPoint(x: x,y: size.height))
                        context.stroke(ceiling,with: .color(.orange),style: StrokeStyle(lineWidth: 1,dash: [3,3]))
                    }
                    if let pointer {
                        var cursor = Path(); let x = pointer*size.width
                        cursor.move(to: CGPoint(x: x,y: 0)); cursor.addLine(to: CGPoint(x: x,y: size.height))
                        context.stroke(cursor,with: .color(.white),lineWidth: 1)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { pointer = min(1,max(0,$0.location.x/max(1,geometry.size.width))) })
            }.frame(height: 88).accessibilityIdentifier("histogram-plot")
            HStack(spacing: 0) {
                HStack { Text("0"); Spacer(); Text("128"); Spacer(); Text("255") }
                if hdr { HStack { Spacer(); Text("+1"); Spacer(); Text("+2"); Spacer(); Text("+3"); Spacer(); Text("+4") } }
            }.font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                metric("Above white",measured.luma.clippedHigh)
                Spacer(minLength: 3); metric("Clipped high",measured.luma.clippedCeiling)
                Spacer(minLength: 3); metric("Clipped low",measured.luma.clippedLow)
            }.accessibilityIdentifier("histogram-clipping")
            if let pointer {
                let reading = MobileHistogramReading.bin(at: pointer,hdr: hdr)
                HStack(spacing: 6) {
                    Text(reading.tail ? String(format: "+%.2f EV",Double(reading.index)/64) : "Code \(reading.index)")
                    ForEach(Array([histogram.red,histogram.green,histogram.blue].enumerated()),id: \.offset) { i,channel in
                        let bins = reading.tail ? channel.hdrBins : channel.bins
                        Text("\(["R","G","B"][i]) \(bins.indices.contains(reading.index) ? bins[reading.index] : 0)")
                            .foregroundStyle([Color.red,.green,.blue][i])
                    }
                }.font(.system(size: 10).monospacedDigit()).accessibilityIdentifier("histogram-readout")
            } else { Text("Touch histogram to inspect bins").font(.caption2).foregroundStyle(.secondary) }
            HStack {
                Text("Sample \(histogram.sampleCount) px")
                Spacer()
                Text(String(format: "Display +%.1f EV",log2(max(1,hdr ? headroom : 1))))
            }.font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain).accessibilityLabel("RGB histogram")
            .onAppear { updateHeadroom() }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)) { _ in updateHeadroom() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in updateHeadroom() }
            .onChange(of: hdr) { _,_ in updateHeadroom() }
    }
    private func updateHeadroom() { headroom = min(16,max(1,Double(UIScreen.main.currentEDRHeadroom))) }
    private func metric(_ label: String,_ ratio: Double) -> some View {
        VStack(alignment: .leading,spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(MobileHistogramReading.percent(ratio)).font(.caption2.monospacedDigit())
        }.accessibilityElement(children: .combine)
    }
}
#endif
