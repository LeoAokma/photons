import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Value snapshot; CGImage and PanoramaSource metadata are immutable.
public struct LCCCreationFrame: Identifiable, @unchecked Sendable {
    public var id=UUID()
    public let source: PanoramaSource
    public var orientation: LCCCaptureOrientation
    public var shiftX=0.0
    public var shiftY=0.0
    public var shiftConfirmed=false
    public let iso: Double?
    public let exposureSeconds: Double?
    public let capturedAt: String?
    public let thumbnail: CGImage?
    public let jpeg: Data?
    public init(url:URL) throws {
        let source=try PanoramaSource(url:url);self.source=source
        guard let orientation=LCCCaptureOrientation(rawValue:source.orientation) else {
            throw PanoramaFailure("\(url.lastPathComponent)：镜像方向暂不支持，请使用未镜像的 LCC 原片。")
        }
        self.orientation=orientation
        if let suggestion=LCCShiftFilename.parse(url.lastPathComponent) { shiftX=suggestion.x;shiftY=suggestion.y }
        let imageSource=CGImageSourceCreateWithURL(url as CFURL,nil)
        let p=imageSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0,0,nil) as? [String:Any] } ?? [:]
        let e=p[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        iso=(e[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        exposureSeconds=(e[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        capturedAt=e[kCGImagePropertyExifDateTimeOriginal as String] as? String
        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:320]
        thumbnail=imageSource.flatMap { CGImageSourceCreateThumbnailAtIndex($0,0,options as CFDictionary) }
        jpeg=thumbnail.flatMap { LCCProfileBuilder.jpeg($0) }
    }
}

public enum LCCProfileBuilder {
    public static func exposureIssue(_ frames:[LCCCreationFrame])->String? {
        for key in [\LCCCreationFrame.iso,\LCCCreationFrame.exposureSeconds] {
            let values=frames.compactMap { $0[keyPath:key] }
            if let first=values.first, values.contains(where: { abs($0-first)>max(0.000001,first*0.01) }) {
                return "这组白板的 ISO 或快门时间不一致。请使用相同曝光拍摄的 LCC 创建 profile。"
            }
        }
        return nil
    }
    public static func create(name:String,aperture:Double?,notes:String,frames:[LCCCreationFrame],
                              sensorLongEdge:Double,sensorShortEdge:Double,
                              cancellation:PanoramaCancellation = .init(),progress:(String)->Void = { _ in }) throws -> LCCLensProfile {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,(1...256).contains(frames.count),
              (5...100).contains(sensorShortEdge),(sensorShortEdge...100).contains(sensorLongEdge),
              frames.allSatisfy(\.shiftConfirmed) else {
            throw PanoramaFailure("请填写镜头名称、传感器尺寸，并确认每张白板的移轴量。")
        }
        if let issue=exposureIssue(frames) { throw PanoramaFailure(issue) }
        guard Set(frames.map { LCCProfileSummary.cameraKey($0.source.camera) }).count==1 else {
            throw PanoramaFailure("同一个 profile 请使用同一型号后背拍摄的白板。")
        }
        // Metadata dimensions must agree with the user's physical sensor dimensions when available.
        for frame in frames {
            if let s=frame.source.sensor,
               abs(max(s.width,s.height)-sensorLongEdge)>0.3 || abs(min(s.width,s.height)-sensorShortEdge)>0.3 {
                throw PanoramaFailure("传感器尺寸与 \(frame.source.url.lastPathComponent) 的 RAW 信息不一致。")
            }
        }
        let context=CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace,.cacheIntermediates:false])
        var captures:[LCCProfileCapture]=[]
        for (index,frame) in frames.enumerated() {
            try cancellation.check();try frame.source.checkUnchanged()
            progress("分析 LCC \(index+1)/\(frames.count)：\(frame.source.url.lastPathComponent)")
            let source=frame.source
            let decoded=try linearImage(source:source,scale:min(1,768/max(source.size.width,source.size.height)))
            let inverse=source.orientation==8 ? 6 : (source.orientation==6 ? 8:source.orientation)
            let oriented=decoded.oriented(forExifOrientation:Int32(inverse))
                .oriented(forExifOrientation:Int32(frame.orientation.rawValue))
            let image=oriented.transformed(by:CGAffineTransform(translationX:-oriented.extent.minX,y:-oriented.extent.minY))
            let portrait=frame.orientation.isPortrait
            let sw=portrait ? sensorShortEdge:sensorLongEdge,sh=portrait ? sensorLongEdge:sensorShortEdge
            let gw=portrait ? 144:192,gh=portrait ? 192:144
            let raster=PanoramaRaster(image:image,context:context,width:gw*4,height:gh*4)
            var values=[Float](),errors=[Float]();values.reserveCapacity(gw*gh*3);errors.reserveCapacity(gw*gh*3)
            for y in 0..<gh {
                if y%16==0 { try cancellation.check() }
                for x in 0..<gw { for c in 0..<3 {
                    var sum=0.0,sq=0.0
                    for dy in 0..<4 { for dx in 0..<4 {
                        let v=Double(raster.rgba[((y*4+dy)*raster.width+x*4+dx)*4+c]);sum+=v;sq+=v*v
                    }}
                    let mean=sum/16
                    values.append(Float(mean));errors.append(Float(sqrt(max(0,sq/16-mean*mean)/16)))
                }}
            }
            let grid=LCCMeasurementGrid(x:(0..<gw).map { (Double($0)+0.5)/Double(gw)*sw-sw/2 },
                y:(0..<gh).map { sh/2-(Double($0)+0.5)/Double(gh)*sh },channels:["R","G","B"],
                values:LCCMeasurementGrid.pack(values),standardError:LCCMeasurementGrid.pack(errors),space:"apple-linear-srgb-6500K-v1")
            let fullLong=Int(max(source.size.width,source.size.height)),fullShort=Int(min(source.size.width,source.size.height))
            captures.append(LCCProfileCapture(id:frame.id,filename:source.url.lastPathComponent,orientation:frame.orientation,
                shiftX:frame.shiftX,shiftY:frame.shiftY,sensorWidth:sw,sensorHeight:sh,
                pixelWidth:portrait ? fullShort:fullLong,pixelHeight:portrait ? fullLong:fullShort,
                iso:frame.iso,exposureSeconds:frame.exposureSeconds,capturedAt:frame.capturedAt,grid:grid,thumbnail:frame.jpeg))
            try source.checkUnchanged()
            context.clearCaches()
        }
        let profile=LCCLensProfile(id:UUID(),name:name.trimmingCharacters(in:.whitespacesAndNewlines),camera:frames[0].source.camera,
                                   aperture:aperture,notes:notes,createdAt:Date(),captures:captures)
        try profile.validate();return profile
    }
    static func linearImage(source:PanoramaSource,scale:Double,whiteBalance:(Float,Float)?=nil) throws -> CIImage {
        try source.checkUnchanged()
        let output:CIImage
        if let raw=CIRAWFilter(imageURL:source.url) {
            raw.isLensCorrectionEnabled=false;raw.isGamutMappingEnabled=false
            raw.boostAmount=0;raw.boostShadowAmount=0;raw.localToneMapAmount=0
            raw.exposure=0;raw.baselineExposure=0;raw.sharpnessAmount=0
            raw.luminanceNoiseReductionAmount=0;raw.colorNoiseReductionAmount=0
            raw.neutralTemperature=whiteBalance?.0 ?? 6500;raw.neutralTint=whiteBalance?.1 ?? 0;raw.scaleFactor=Float(scale)
            guard let image=raw.outputImage else {throw PanoramaFailure("无法解码 \(source.url.lastPathComponent)")};output=image
        } else if let image=CIImage(contentsOf:source.url,options:[.applyOrientationProperty:true]) {output=image}
        else {throw PanoramaFailure("无法解码 \(source.url.lastPathComponent)")}
        let normal=output.transformed(by:CGAffineTransform(translationX:-output.extent.minX,y:-output.extent.minY))
        return normal.transformed(by:CGAffineTransform(scaleX:source.size.width*scale/normal.extent.width,y:source.size.height*scale/normal.extent.height))
    }
    static func jpeg(_ cg:CGImage)->Data? {
        let output=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(output,UTType.jpeg.identifier as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(dest,cg,[kCGImageDestinationLossyCompressionQuality:0.75] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? output as Data:nil
    }
}
