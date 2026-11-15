import Foundation
import CoreImage
import CoreGraphics
import ImageIO

public final class PanoramaEngine {
    public static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let context = CIContext(options: [.workingColorSpace: linearSpace, .cacheIntermediates: false])
    public init() {}
    public typealias Progress = (String) -> Void

    func decoded(_ source: PanoramaSource, scale: Double, whiteBalance: (Float,Float)?) throws -> CIImage {
        try source.checkUnchanged()
        let output: CIImage
        if let raw = CIRAWFilter(imageURL: source.url) {
            raw.isLensCorrectionEnabled = false
            raw.boostAmount = 0; raw.isGamutMappingEnabled = false
            raw.scaleFactor = Float(scale); raw.exposure = 0
            raw.sharpnessAmount = 0; raw.luminanceNoiseReductionAmount = 0
            if let wb = whiteBalance { raw.neutralTemperature = wb.0; raw.neutralTint = wb.1 }
            guard let image = raw.outputImage else { throw PanoramaFailure("RAW 解码失败：\(source.url.lastPathComponent)") }
            output = image
        } else {
            guard let image = CIImage(contentsOf: source.url, options: [.applyOrientationProperty:true]) else {
                throw PanoramaFailure("读取失败：\(source.url.lastPathComponent)")
            }
            output = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        }
        // Decoder scales may round differently. Normalize to one exact affine source coordinate
        // system before creating a proxy. This is also the coordinate system used at scale == 1.
        let normalized = output.transformed(by:CGAffineTransform(translationX:-output.extent.minX,y:-output.extent.minY))
        let desired = CGSize(width:source.size.width*scale,height:source.size.height*scale)
        return normalized.transformed(by:CGAffineTransform(scaleX:desired.width/output.extent.width,
                                                           y:desired.height/output.extent.height))
    }

    func materialize(_ image: CIImage) -> CIImage {
        let w = Int(ceil(image.extent.width)), h = Int(ceil(image.extent.height))
        var data = Data(count:w*h*8)
        data.withUnsafeMutableBytes { p in
            context.render(image,toBitmap:p.baseAddress!,rowBytes:w*8,
                           bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAh,colorSpace:Self.linearSpace)
        }
        return CIImage(bitmapData:data,bytesPerRow:w*8,size:CGSize(width:w,height:h),format:.RGBAh,colorSpace:Self.linearSpace)
    }

    public func analyze(urls: [URL], options: PanoramaOptions = .init(),
                        cancellation: PanoramaCancellation = .init(), progress: Progress = { _ in }) throws -> PanoramaPlan {
        guard urls.count >= 2 else { throw PanoramaFailure(urls.isEmpty ? "请先选中需要拼接的图片" : "请至少选中两张需要拼接的图片") }
        guard urls.count <= 16 else { throw PanoramaFailure("第一版一次最多支持 16 张图片，请分组拼接。") }
        var sources: [PanoramaSource] = []
        for url in urls { try cancellation.check(); sources.append(try PanoramaSource(url:url)) }
        guard let first = sources.first else { throw PanoramaFailure("没有输入图片") }
        guard sources.allSatisfy({ abs($0.size.width-first.size.width)<2 && abs($0.size.height-first.size.height)<2 && $0.orientation == first.orientation }) else {
            throw PanoramaFailure("移轴接片要求各张照片尺寸和方向一致；请使用同一后背、同一朝向的原始图片。")
        }
        let wb: (Float,Float)? = first.temperature.flatMap { t in first.tint.map { (t,$0) } }
        let scale = min(1,2048/max(first.size.width,first.size.height))
        var images: [CIImage] = [], grays: [GrayRaster] = [], coarse: [GrayRaster] = []
        for (i,source) in sources.enumerated() {
            try cancellation.check(); progress("读取 RAW \(i+1)/\(sources.count)：\(source.url.lastPathComponent)")
            let image = try materialize(decoded(source,scale:scale,whiteBalance:wb)); images.append(image)
            grays.append(PanoramaRaster(image:image,context:context,width:Int(image.extent.width),height:Int(image.extent.height)).gray)
            coarse.append(PanoramaRaster(image:image,context:context,width:Int(image.extent.width)/2,height:Int(image.extent.height)/2).gray)
        }
        struct Edge { let a: Int; let b: Int; let offset: CGPoint; let score: Double }
        var edges: [Edge] = []
        for a in 0..<sources.count-1 { for b in a+1..<sources.count {
            try cancellation.check(); progress("匹配重叠区域 \(a+1) ↔ \(b+1)")
            if let match = try TranslationRegistration.align(coarse[a],coarse[b],cancellation:cancellation) {
                let initial = CGPoint(x:match.offset.x*Double(grays[a].width)/Double(coarse[a].width),
                                      y:match.offset.y*Double(grays[a].height)/Double(coarse[a].height))
                let refined = TranslationRegistration.refine(grays[a],grays[b],offset:initial,radius:2)
                if refined.score > 0.7 {
                    edges.append(Edge(a:a,b:b,offset:CGPoint(x:refined.offset.x/scale,y:refined.offset.y/scale),score:refined.score))
                }
            }
        }}
        // Maximum-confidence spanning tree: input filename order does not determine image layout.
        var positions = [CGPoint?](repeating:nil,count:sources.count), scores = [Double](repeating:1,count:sources.count)
        positions[0] = .zero
        while positions.contains(where: { $0 == nil }) {
            let choices = edges.filter { (positions[$0.a] == nil) != (positions[$0.b] == nil) }
            guard let edge = choices.max(by: { $0.score < $1.score }) else {
                let missing = sources.indices.filter { positions[$0] == nil }.map { sources[$0].url.lastPathComponent }.joined(separator:"、")
                throw PanoramaFailure("未找到可靠的平移重叠：\(missing)。请检查照片是否来自同一组移轴拍摄、重叠是否足够；旋转机位的照片需使用普通接片。")
            }
            if let a = positions[edge.a] {
                positions[edge.b] = CGPoint(x:a.x+edge.offset.x,y:a.y+edge.offset.y); scores[edge.b] = edge.score
            } else if let b = positions[edge.b] {
                positions[edge.a] = CGPoint(x:b.x-edge.offset.x,y:b.y-edge.offset.y); scores[edge.a] = edge.score
            }
        }
        var origins = positions.map { $0! }
        // Reject contradictory loops instead of producing an apparently successful crooked stitch.
        for edge in edges where edge.score > 0.8 {
            let residual = hypot(origins[edge.b].x-origins[edge.a].x-edge.offset.x,
                                 origins[edge.b].y-origins[edge.a].y-edge.offset.y)
            if residual * scale > 3 { throw PanoramaFailure("照片间的平移关系不一致，可能存在视差或机位旋转。请减少选图并检查拍摄方式。") }
        }
        let minX = floor(origins.map(\.x).min()!), minY = floor(origins.map(\.y).min()!)
        origins = origins.map { CGPoint(x:$0.x-minX,y:$0.y-minY) }
        let size = CGSize(width:ceil(origins.map(\.x).max()!+first.size.width),height:ceil(origins.map(\.y).max()!+first.size.height))
        guard size.width*size.height < 600_000_000 else { throw PanoramaFailure("拼接结果超过 6 亿像素，请减少输入图片。") }
        var plan = PanoramaPlan(sources:sources,origins:origins,size:size,registrationScores:scores,whiteBalance:wb,
                                gains:[Double](repeating:1,count:sources.count),ownership:[],maskWidth:0,maskHeight:0,
                                optical:OpticalEstimate(center:nil,confidence:0,explanation:"尚未估计",occludedEdges:[]),
                                options:options,previewScale:scale,previewImages:images,preview:nil)
        plan = try update(plan,options:options,cancellation:cancellation,progress:progress)
        return plan
    }

    public func update(_ original: PanoramaPlan, options: PanoramaOptions,
                       cancellation: PanoramaCancellation = .init(), progress: Progress = { _ in }) throws -> PanoramaPlan {
        var plan = original; plan.options = options
        progress("分析暗角、红移和重叠冲突")
        try PanoramaSeams.prepare(&plan,context:context,cancellation:cancellation)
        try cancellation.check(); progress("生成拼接预览")
        let scale = min(1,1800/max(plan.size.width,plan.size.height))
        let scene = composite(plan,images:plan.previewImages,imageScale:plan.previewScale,outputScale:scale)
        plan.preview = context.createCGImage(scene,from:scene.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return plan
    }

    func composite(_ plan: PanoramaPlan, images: [CIImage], imageScale: Double, outputScale: Double) -> CIImage {
        let bounds = CGRect(x:0,y:0,width:ceil(plan.size.width*outputScale),height:ceil(plan.size.height*outputScale))
        var result = CIImage(color:.clear).cropped(to:bounds)
        for i in images.indices {
            let hasWeights = plan.blendMasks.indices.contains(i)
            let data = hasWeights ? plan.blendMasks[i] : Data(plan.ownership.map { $0 == Int16(i) ? UInt8(255) : UInt8(0) })
            let mask = CIImage(bitmapData:data,bytesPerRow:plan.maskWidth * (hasWeights ? 4:1),
                               size:CGSize(width:plan.maskWidth,height:plan.maskHeight),format:hasWeights ? .Lf:.L8,colorSpace:nil)
                .transformed(by:CGAffineTransform(scaleX:plan.size.width*outputScale/Double(plan.maskWidth),
                                                  y:plan.size.height*outputScale/Double(plan.maskHeight)))
            let image = images[i].transformed(by:CGAffineTransform(scaleX:outputScale/imageScale,y:outputScale/imageScale))
                .transformed(by:CGAffineTransform(translationX:plan.origins[i].x*outputScale,
                                                  y:(plan.size.height-plan.origins[i].y-plan.sources[i].size.height)*outputScale))
                .applyingFilter("CIExposureAdjust",parameters:["inputEV":log2(plan.gains[i])])
            let weighted = image.clampedToExtent().applyingFilter("CIBlendWithMask",parameters:[
                "inputBackgroundImage":CIImage(color:.clear),"inputMaskImage":mask]).cropped(to:bounds)
            // The masks form a partition of unity. Add their premultiplied contributions;
            // repeated source-over would darken every interpolated seam (0.5 + 0.5*0.5 != 1).
            result = weighted.applyingFilter("CIAdditionCompositing",parameters:["inputBackgroundImage":result]).cropped(to:bounds)
        }
        return result
    }

    public enum OutputFormat: String, CaseIterable { case dng, tiff }
    public func export(_ plan: PanoramaPlan, to destination: URL, format: OutputFormat,
                       cancellation: PanoramaCancellation = .init(), progress: Progress = { _ in }) throws {
        guard !plan.sources.contains(where: { $0.url.standardizedFileURL == destination.standardizedFileURL }) else {
            throw PanoramaFailure("不能覆盖输入图片。")
        }
        // Materialize one decode per source, rather than re-decoding a 100 MP RAW for every tile.
        // Half-float storage is 8 bytes/pixel; enforce a memory bound before starting the job.
        let bytes = plan.sources.reduce(0.0) { $0+$1.size.width*$1.size.height*8 }
        guard bytes < Double(ProcessInfo.processInfo.physicalMemory)*0.45 else {
            throw PanoramaFailure("这组图片超出当前内存预算，请减少拼接张数。")
        }
        var images: [CIImage] = []
        for (i,source) in plan.sources.enumerated() {
            try cancellation.check(); progress("全分辨率解码 \(i+1)/\(plan.sources.count)")
            images.append(try materialize(decoded(source,scale:1,whiteBalance:plan.whiteBalance)))
        }
        try cancellation.check()
        let scene = composite(plan,images:images,imageScale:1,outputScale:1)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".photons-\(UUID().uuidString).\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at:temp); context.clearCaches() }
        if format == .dng {
            try LinearDNGWriter.write(image:scene,context:context,to:temp,cancellation:cancellation,progress:progress)
        } else {
            progress("写入 16 位 TIFF（LZW）")
            guard let cg = context.createCGImage(scene,from:scene.extent,format:.RGBA16,
                                                 colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!),
                  let destination = CGImageDestinationCreateWithURL(temp as CFURL,"public.tiff" as CFString,1,nil) else {
                throw PanoramaFailure("无法创建 16 位 TIFF")
            }
            CGImageDestinationAddImage(destination,cg,[kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFCompression:5]] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PanoramaFailure("TIFF 写入失败，请检查剩余磁盘空间。") }
        }
        try cancellation.check()
        if FileManager.default.fileExists(atPath:destination.path) {
            _ = try FileManager.default.replaceItemAt(destination,withItemAt:temp)
        } else { try FileManager.default.moveItem(at:temp,to:destination) }
    }
}
