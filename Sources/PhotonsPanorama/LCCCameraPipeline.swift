import PhotonsLocalization
import Foundation
import CoreImage
import PhotonsExtensions

/// A four-channel map in unrotated sensor coordinates. Exactly the same normalized positions
/// drive the interactive proxy and full-resolution CFA, independently of the preview size.
public struct LCCCameraGainMap: Codable {
    enum CodingKeys:String,CodingKey { case width,height,values,clippedColors }
    let width:Int,height:Int
    let values:[SIMD4<Float>]
    private(set) var clippedColors:LCCClippedColorMap?
    init(field:LCCCorrectionField,source:PanoramaSource,origin:CGPoint,panoramaSize:CGSize,sensor:SensorSize,offset:CGPoint,
         bodyOrientation:PanoramaBodyOrientation = .degrees0) {
        width=257;height=193
        var grid:[SIMD4<Float>]=[];grid.reserveCapacity(width*height)
        for y in 0..<height {for x in 0..<width {
            let u=Double(x)/Double(width-1),v=Double(y)/Double(height-1)
            let p=Self.orient(u,v,orientation:source.orientation)
            let point=CGPoint(x:(origin.x+p.x*source.size.width-panoramaSize.width/2)*sensor.width/source.size.width-offset.x,
                              y:(panoramaSize.height/2-origin.y-p.y*source.size.height)*sensor.height/source.size.height-offset.y)
            let gain=field.cameraGain(at:bodyOrientation.inverse.rotate(point)) ?? SIMD4<Double>(repeating:1)
            grid.append(SIMD4<Float>(gain))
        }}
        values=grid
    }
    static func orient(_ u:Double,_ v:Double,orientation:Int)->CGPoint {
        switch orientation {case 3:return CGPoint(x:1-u,y:1-v);case 6:return CGPoint(x:1-v,y:u);case 8:return CGPoint(x:v,y:1-u);default:return CGPoint(x:u,y:v)}
    }
    func gain(_ u:Double,_ v:Double)->SIMD4<Float> {
        let xx=min(Double(width-1),max(0,u*Double(width-1))),yy=min(Double(height-1),max(0,v*Double(height-1)))
        let x=min(width-2,Int(xx)),y=min(height-2,Int(yy)),fx=Float(xx-Double(x)),fy=Float(yy-Double(y)),p=y*width+x
        return (values[p]*(1-fx)+values[p+1]*fx)*(1-fy)+(values[p+width]*(1-fx)+values[p+width+1]*fx)*fy
    }
    func preparingHighlights(_ raw:CameraMosaic,neutral:SIMD3<Double>?)->Self {
        var result=self;result.clippedColors=LCCClippedColorMap(raw:raw,gain:self,fallback:neutral);return result
    }
    // Older worker snapshots contain gains without the preview's colour reference.
    func restoringHighlights(for source: PanoramaSource, neutral: SIMD3<Double>?) throws -> Self {
        guard clippedColors == nil else { return self }
        let proxy = try LCCCameraPipeline.read(source, maxDimension: LCCCameraPipeline.previewLongEdge)
        return preparingHighlights(proxy, neutral: neutral)
    }
    func opcode(for raw:CameraMosaic,normalization:Double)->Data {
        func be32(_ v:UInt32)->Data {var v=v.bigEndian;return Data(bytes:&v,count:4)}
        func be64(_ v:Double)->Data {var v=v.bitPattern.bigEndian;return Data(bytes:&v,count:8)}
        var data=be32(4)
        for site in 0..<4 {
            var payload=Data()
            for n in [site/2,site%2,raw.height,raw.width,0,1,2,2,height,width] {payload += be32(UInt32(n))}
            payload += be64(1/Double(height-1))+be64(1/Double(width-1))+be64(0)+be64(0)+be32(1)
            for v in values {let c=raw.pattern[site],g=(c==1 || c==3) ? sqrt(v.y*v.w):v[c];payload += be32((g/Float(normalization)).bitPattern)}
            data += be32(9)+be32(0x01030000)+be32(0)+be32(UInt32(payload.count))+payload
        }
        return data
    }

}

struct LCCWhiteBalanceReading {
    let temperature:Float,tint:Float
    let neutral:SIMD3<Double>
}

enum LCCCameraPipeline {
    static let previewLongEdge = 2048
    static func read(_ source:PanoramaSource,maxDimension:Int?=nil) throws->CameraMosaic {
        try source.checkUnchanged()
        let portrait=[6,8].contains(source.orientation)
        let result=try CameraMosaic(url:source.url,visibleWidth:Int(portrait ? source.size.height:source.size.width),
                                visibleHeight:Int(portrait ? source.size.width:source.size.height),maxDimension:maxDimension)
        try source.checkUnchanged();return result
    }
    static func cameraImage(_ raw:CameraMosaic)->CIImage {
        let w=raw.width/2,h=raw.height/2
        var pixels=[Float](repeating:1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {
            var c=SIMD4<Float>.zero
            for s in 0..<4 {c[raw.pattern[s]]=raw.samples[(y*2+s/2)*raw.width+x*2+s%2]}
            let p=(y*w+x)*4;pixels[p]=c.x;pixels[p+1]=(c.y+c.w)/2;pixels[p+2]=c.z
        }}
        let data=pixels.withUnsafeBytes {Data($0)}
        return CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
            .oriented(forExifOrientation:Int32(raw.orientation))
    }
    static func whiteBalance(_ raw:CameraMosaic,gain:LCCCameraGainMap,whitePlate:Bool) throws->LCCWhiteBalanceReading {
        var r:[Double]=[],b:[Double]=[],greens:[Double]=[]
        let stridePixels=max(2,(raw.width/100)/2*2)
        for y in stride(from:raw.height/20/2*2,to:raw.height*19/20-2,by:stridePixels) {
            for x in stride(from:raw.width/20/2*2,to:raw.width*19/20-2,by:stridePixels) {
                var c=SIMD4<Double>.zero
                for s in 0..<4 {c[raw.pattern[s]]=Double(raw.samples[(y+s/2)*raw.width+x+s%2])}
                c *= SIMD4<Double>(gain.gain((Double(x)+1)/Double(raw.width),(Double(y)+1)/Double(raw.height)))
                let green=(c.y+c.w)/2
                guard min(c.x,c.z,green)>0.0001 else {continue}
                r.append(c.x/green);b.append(c.z/green);greens.append(green)
            }
        }
        guard r.count>20 else {throw PanoramaFailure(L10n.tr("ac13861872e3"))}
        if !whitePlate {
            // Estimate illumination only after spatial shading removal. Bright neutral candidates
            // are less dominated by foliage/shadows than an unweighted scene grey-world average.
            let low=median(greens)
            let selected=r.indices.filter {greens[$0]>=low}
            r=selected.map {r[$0]};b=selected.map {b[$0]}
        }
        let neutral=[median(r),1,median(b)]
        let dng=raw.dng(neutral:neutral)
        guard let filter=CIRAWFilter(imageData:dng.data,identifierHint:"com.adobe.raw-image") else {throw PanoramaFailure(L10n.tr("05cb7d84c9df"))}
        return LCCWhiteBalanceReading(temperature:filter.neutralTemperature,tint:filter.neutralTint,neutral:SIMD3(neutral[0],1,neutral[2]))
    }
    /// Sensor clipping is different from post-LCC overexposure. Reconstruct only saturated
    /// channels from surviving channels and the local highlight colour. Never shift scene WB to
    /// hide clipping. This estimates missing colour, it cannot recover lost sensor information.
    static func recoverClipped(original: SIMD4<Float>, corrected: SIMD4<Float>, neutral: SIMD3<Double>?,
                               clippedFraction: SIMD4<Float> = .zero) -> SIMD4<Float> {
        guard let neutral else { return corrected }
        let ratios = SIMD4<Float>(Float(neutral.x), 1, Float(neutral.z), 1)
        var weights = SIMD4<Float>.zero
        var sum: Float = 0, support: Float = 0
        for c in 0..<4 {
            let knee = min(1, max(0, (original[c] - 0.97) / 0.025))
            weights[c] = max(clippedFraction[c], knee * knee * (3 - 2 * knee))
            let headroom = min(1, max(0, (0.97 - original[c]) / 0.04))
            let donor = (1 - clippedFraction[c]) * headroom * headroom * (3 - 2 * headroom)
                * (c == 1 || c == 3 ? 0.5 : 1)
            if original[c] > 0.001 {
                sum += donor * corrected[c] / ratios[c]
                support += donor
            }
        }
        // With every channel saturated only a lower bound on brightness survives. Fade
        // towards it as the last usable donor approaches saturation (including either green).
        let missingSupport = max(0, 1 - support)
        let brightness = (sum + missingSupport * (corrected / ratios).max()) / (support + missingSupport)
        return corrected + weights * (ratios * brightness - corrected)
    }
    static func develop(_ raw:CameraMosaic,gain:LCCCameraGainMap,whiteBalance:(Float,Float)?,highlightNeutral:SIMD3<Double>?=nil,size:CGSize,scale:Double,
                        cancellation:PanoramaCancellation = .init()) throws->CIImage {
        let highlightColors=gain.clippedColors ?? LCCClippedColorMap(raw:raw,gain:gain,fallback:highlightNeutral)
        var prepared=raw.samples,peak=1.0
        for y in stride(from:0,to:raw.height,by:2) {
            if y%64==0 {try cancellation.check()}
            for x in stride(from:0,to:raw.width,by:2) {
                let g=gain.gain((Double(x)+1)/Double(raw.width),(Double(y)+1)/Double(raw.height)),common=sqrt(g.y*g.w)
                var original = SIMD4<Float>.zero, fraction = SIMD4<Float>.zero
                for site in 0..<4 {
                    let p = (y + site / 2) * raw.width + x + site % 2, c = raw.pattern[site]
                    original[c] = raw.samples[p]
                    fraction[c] = raw.clipping?[p] ?? 0
                }
                var corrected = original * g
                if original.max() > 0.97 || fraction.max() > 0 {
                    let local = highlightColors.neutral((Double(x) + 1) / Double(raw.width),
                                                       (Double(y) + 1) / Double(raw.height))
                    corrected = recoverClipped(original: original, corrected: corrected,
                                               neutral: local, clippedFraction: fraction)
                }
                peak=max(peak,Double(corrected.max()))
                for site in 0..<4 {
                    let c=raw.pattern[site],divisor=(c==1 || c==3) ? common:g[c]
                    prepared[(y+site/2)*raw.width+x+site%2]=corrected[c]/divisor
                }
            }
        }
        let normalization=max(1,peak*4)
        let dng=raw.dng(samples:prepared,gainOpcode:gain.opcode(for:raw,normalization:normalization))
        guard let filter=CIRAWFilter(imageData:dng.data,identifierHint:"com.adobe.raw-image") else {throw PanoramaFailure(L10n.tr("a0c9e40082d3"))}
        filter.isLensCorrectionEnabled=false;filter.isGamutMappingEnabled=false
        filter.boostAmount=0;filter.boostShadowAmount=0;filter.localToneMapAmount=0;filter.exposure=0;filter.baselineExposure=0;filter.shadowBias=0
        filter.sharpnessAmount=0;filter.luminanceNoiseReductionAmount=0;filter.colorNoiseReductionAmount=0
        if let wb=whiteBalance {filter.neutralTemperature=wb.0;filter.neutralTint=wb.1}
        guard let result=filter.outputImage else {throw PanoramaFailure(L10n.tr("804fd97215e0"))}
        let normalized=result.transformed(by:CGAffineTransform(translationX:-result.extent.minX,y:-result.extent.minY))
        return normalized.transformed(by:CGAffineTransform(scaleX:size.width*scale/normalized.extent.width,y:size.height*scale/normalized.extent.height))
            .applyingFilter("CIExposureAdjust",parameters:["inputEV":dng.exposure+log2(normalization)])
    }
}

/// Propagate colour ratios from unsaturated neighbours into clipped regions. This supplies
/// local colour (e.g. blue sky), instead of forcing every reconstructed highlight to neutral.
struct LCCClippedColorMap: Codable {
    // The middle log ratio is zero. Keep only red/green and blue/green in the worker snapshot.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(LCCMeasurementGrid.pack(colors.flatMap { [Float($0.x), Float($0.z)] }))
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let bytes = try container.decode(Data.self)
        guard bytes.count == width * height * 2 * MemoryLayout<Float>.size else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid highlight colour grid size")
        }
        let values = LCCMeasurementGrid.unpack(bytes)
        guard values.allSatisfy({ exp($0).isFinite && exp($0) > 0 }) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid highlight colour ratio")
        }
        colors = stride(from: 0, to: values.count, by: 2).map { SIMD3(Double(values[$0]), 0, Double(values[$0 + 1])) }
    }
    let width=96,height=72
    var colors:[SIMD3<Double>]
    init(raw:CameraMosaic,gain:LCCCameraGainMap,fallback:SIMD3<Double>?) {
        let base=fallback ?? SIMD3(1,1,1)
        var sums=[SIMD3<Double>](repeating:.zero,count:width*height),counts=[Int](repeating:0,count:width*height)
        let step=max(2,(raw.width/400)/2*2)
        // A clipped channel needs the colour of a highlight. Dark objects next to it can
        // have clean but unrelated ratios. Use the brightest available quarter stop of sensor
        // measurements, before spatial gain, so the correction cannot promote a shadow.
        func reference(x: Int, y: Int, atLeast minimum: Float) -> (level: Float, corrected: SIMD4<Float>)? {
            var sample = SIMD4<Float>.zero
            for site in 0..<4 {
                let index = (y + site / 2) * raw.width + x + site % 2
                if (raw.clipping?[index] ?? 0) > 0 { return nil }
                sample[raw.pattern[site]] = raw.samples[index]
            }
            let level = sample.max()
            guard level >= minimum, level < 0.95, sample.min() > 0.001 else { return nil }
            // The four Bayer sites sample adjacent positions. A block astride a
            // silhouette can measure red on one object and blue on another.
            // Compare each site to the same colour in surrounding blocks before using its ratio.
            for dy in stride(from: -2, through: 2, by: 2) {
                for dx in stride(from: -2, through: 2, by: 2) where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx + 1 < raw.width, ny + 1 < raw.height else { continue }
                    for site in 0..<4 {
                        let index = (ny + site / 2) * raw.width + nx + site % 2
                        let neighbor = raw.samples[index], center = sample[raw.pattern[site]]
                        guard (raw.clipping?[index] ?? 0) == 0, neighbor < 0.95,
                              abs(neighbor - center) <= 0.25 * max(neighbor, center) else { return nil }
                    }
                }
            }
            let corrected = sample * gain.gain((Double(x) + 1) / Double(raw.width),
                                               (Double(y) + 1) / Double(raw.height))
            guard (corrected.y + corrected.w) / 2 > 0.03 else { return nil }
            return (level, corrected)
        }
        let rows = stride(from: 0, to: raw.height - 1, by: step)
        let columns = stride(from: 0, to: raw.width - 1, by: step)
        var brightest: Float = 0
        for y in rows {
            for x in columns {
                if let sample = reference(x: x, y: y, atLeast: brightest) { brightest = sample.level }
            }
        }
        let threshold = brightest * exp2(Float(-0.25))
        for y in rows {
            for x in columns {
                guard let sample = reference(x: x, y: y, atLeast: threshold) else { continue }
                let c = sample.corrected, green = Double(c.y + c.w) / 2
                let cell = (y * height / raw.height) * width + x * width / raw.width
                sums[cell] += SIMD3(log(Double(c.x) / green), 0, log(Double(c.z) / green))
                counts[cell] += 1
            }
        }
        let initial=SIMD3(log(base.x),0,log(base.z))
        colors=sums.indices.map {counts[$0]>0 ? sums[$0]/Double(counts[$0]):initial}
        var known=counts.map {$0>0},queue=known.indices.filter {known[$0]},cursor=0
        while cursor<queue.count {
            let p=queue[cursor];cursor += 1
            for q in [p%width>0 ? p-1:-1,p%width+1<width ? p+1:-1,p>=width ? p-width:-1,p+width<colors.count ? p+width:-1] where q>=0 && !known[q] {
                colors[q]=colors[p];known[q]=true;queue.append(q)
            }
        }
        // Harmonic interpolation removes nearest-neighbour colour boundaries in the holes.
        for _ in 0..<100 {
            var next=colors
            for y in 0..<height {for x in 0..<width where counts[y*width+x]==0 {
                let p=y*width+x
                let neighbours=[colors[y*width+max(0,x-1)],colors[y*width+min(width-1,x+1)],colors[max(0,y-1)*width+x],colors[min(height-1,y+1)*width+x]]
                next[p]=neighbours.reduce(.zero,+)/4
            }}
            colors=next
        }
    }
    func neutral(_ u:Double,_ v:Double)->SIMD3<Double> {
        let xx=min(Double(width-1),max(0,u*Double(width)-0.5)),yy=min(Double(height-1),max(0,v*Double(height)-0.5))
        let x=min(width-2,Int(xx)),y=min(height-2,Int(yy)),fx=xx-Double(x),fy=yy-Double(y),p=y*width+x
        let log=(colors[p]*(1-fx)+colors[p+1]*fx)*(1-fy)+(colors[p+width]*(1-fx)+colors[p+width+1]*fx)*fy
        return SIMD3(exp(log.x),1,exp(log.z))
    }
}
