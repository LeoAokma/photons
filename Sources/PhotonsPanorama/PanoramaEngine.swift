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
        try LCCProfileBuilder.linearImage(source:source,scale:scale,whiteBalance:whiteBalance)
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

    public func analyze(urls: [URL], options: PanoramaOptions = .init(),knownPositions:[Int:CGPoint]=[:],sensorOverride:SensorSize?=nil,
                        cancellation: PanoramaCancellation = .init(), progress: Progress = { _ in }) throws -> PanoramaPlan {
        guard urls.count >= 2 else { throw PanoramaFailure(urls.isEmpty ? "请先选中需要拼接的图片" : "请至少选中两张需要拼接的图片") }
        guard urls.count <= 16 else { throw PanoramaFailure("第一版一次最多支持 16 张图片，请分组拼接。") }
        var sources: [PanoramaSource] = []
        for url in urls { try cancellation.check(); sources.append(try PanoramaSource(url:url)) }
        guard let first = sources.first else { throw PanoramaFailure("没有输入图片") }
        guard sources.allSatisfy({ abs($0.size.width-first.size.width)<2 && abs($0.size.height-first.size.height)<2 && $0.orientation == first.orientation }) else {
            throw PanoramaFailure("移轴接片要求各张照片尺寸和方向一致；请使用同一后背、同一朝向的原始图片。")
        }
        let readings=sources.compactMap {s->(Float,Float)? in
            guard let temperature=s.temperature,let tint=s.tint,temperature.isFinite,tint.isFinite else {return nil}
            return (temperature,tint)
        }
        let wb:(Float,Float)?=readings.isEmpty ? nil:(readings.reduce(0) {$0+$1.0}/Float(readings.count),readings.reduce(0) {$0+$1.1}/Float(readings.count))
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
            let match:TranslationRegistration.Match?
            if let pa=knownPositions[a],let pb=knownPositions[b],let sensor=sensorOverride ?? first.sensor {
                progress("依据移轴读数搜索 \(a+1) ↔ \(b+1)")
                let expected=CGPoint(x:(pb.x-pa.x)/sensor.width*Double(coarse[a].width),y:-(pb.y-pa.y)/sensor.height*Double(coarse[a].height))
                match=try TranslationRegistration.align(coarse[a],coarse[b],near:expected,
                    radius:max(Double(coarse[a].width)/sensor.width,Double(coarse[a].height)/sensor.height)*1.5,cancellation:cancellation)
            } else {match=try TranslationRegistration.align(coarse[a],coarse[b],cancellation:cancellation)}
            if let match {
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
                throw PanoramaFailure("未找到可靠的平移重叠：\(missing)。可点击示意图，输入这些照片和一张基准照片的移轴量，再点击“按移轴信息重新匹配”。")
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
        guard original.isRegistered else {throw PanoramaFailure("请先完成照片配准。")}
        var plan = original; plan.options = options
        progress("分析暗角、红移和重叠冲突")
        try PanoramaSeams.prepare(&plan,context:context,cancellation:cancellation)
        try cancellation.check(); progress("生成拼接预览")
        renderPreview(&plan)
        return plan
    }

    func renderPreview(_ plan:inout PanoramaPlan) {
        let scale=min(1,1800/max(plan.size.width,plan.size.height))
        plan.lccState?.highlightEV=0
        if plan.lccState?.protectHighlights == true {
            var measuring=plan;measuring.lccState?.exposureEV=0
            let scene=composite(measuring,images:plan.previewImages,imageScale:plan.previewScale,outputScale:plan.previewScale)
            let raster=PanoramaRaster(image:scene,context:context,width:900,height:max(2,Int(900*scene.extent.height/scene.extent.width)))
            let peaks=stride(from:0,to:raster.rgba.count,by:4).compactMap {i->Float? in
                let v=max(raster.rgba[i],raster.rgba[i+1],raster.rgba[i+2])
                return v.isFinite && raster.rgba[i+3]>0.5 ? v:nil
            }.sorted()
            // A hot pixel or specular glint must not underexpose the entire panorama.
            // The same shoulder handles the remaining brightest 0.5% without clipping.
            let peak=peaks.isEmpty ? 0:Double(peaks[Int(Double(peaks.count-1)*0.995)])
            if peak.isFinite,peak>0.9 {plan.lccState?.highlightEV=log2(0.9/peak)}
        }
        var scene=composite(plan,images:plan.previewImages,imageScale:plan.previewScale,outputScale:scale)
        if plan.lccState?.protectHighlights == true {scene=Self.protectedDisplay(scene)}
        plan.preview=context.createCGImage(scene,from:scene.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
    }

    // One continuous, hue-preserving shoulder for SDR preview/TIFF. The global exposure
    // normally keeps samples below the knee; this catches fine highlights absent at proxy
    // resolution. Linear DNG keeps the original floating-point headroom instead.
    private static let highlightKernel=CIColorKernel(source:"""
        kernel vec4 protectHighlights(__sample s) {
            float peak=max(s.r,max(s.g,s.b));
            float excess=max(0.0,peak-0.9);
            float mapped=0.9+0.1*excess/(excess+0.1);
            float scale=peak>0.9 ? mapped/peak : 1.0;
            return vec4(s.rgb*scale,s.a);
        }
        """)!
    static func protectedDisplay(_ image:CIImage)->CIImage {
        highlightKernel.apply(extent:image.extent,arguments:[image])!
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
            let source=plan.photometricGains.indices.contains(i) ? applyGain(images[i],gain:plan.photometricGains[i],scale:imageScale):images[i]
            let image = source.transformed(by:CGAffineTransform(scaleX:outputScale/imageScale,y:outputScale/imageScale))
                .transformed(by:CGAffineTransform(translationX:plan.origins[i].x*outputScale,
                                                  y:(plan.size.height-plan.origins[i].y-plan.sources[i].size.height)*outputScale))
                .applyingFilter("CIExposureAdjust",parameters:["inputEV":log2(plan.gains[i])])
            let weighted = image.clampedToExtent().applyingFilter("CIBlendWithMask",parameters:[
                "inputBackgroundImage":CIImage(color:.clear),"inputMaskImage":mask]).cropped(to:bounds)
            // The masks form a partition of unity. Add their premultiplied contributions;
            // repeated source-over would darken every interpolated seam (0.5 + 0.5*0.5 != 1).
            result = weighted.applyingFilter("CIAdditionCompositing",parameters:["inputBackgroundImage":result]).cropped(to:bounds)
        }
        if let lcc=plan.lccState,lcc.highlightEV+lcc.exposureEV != 0 {
            result=result.applyingFilter("CIExposureAdjust",parameters:["inputEV":lcc.highlightEV+lcc.exposureEV])
        }
        if let crop=plan.lccState?.cropRect {
            let rect=CGRect(x:crop.minX*outputScale,y:(plan.size.height-crop.maxY)*outputScale,width:crop.width*outputScale,height:crop.height*outputScale)
            return result.cropped(to:rect).transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY))
        }
        return result
    }

    public enum OutputFormat: String, CaseIterable { case dng, tiff }
    public func export(_ plan: PanoramaPlan, to destination: URL, format: OutputFormat,
                       cancellation: PanoramaCancellation = .init(), progress: Progress = { _ in }) throws {
        guard plan.isRegistered else {throw PanoramaFailure("尚未完成配准，不能导出。")}
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
            if let lcc=plan.lccState,lcc.usesFixedDecode[i] {
                if lcc.cameraGains.indices.contains(i),let map=lcc.cameraGains[i] {
                    let raw=try LCCCameraPipeline.read(source)
                    images.append(try materialize(LCCCameraPipeline.develop(raw,gain:map,whiteBalance:lcc.whiteBalance,highlightNeutral:lcc.highlightNeutral,size:source.size,scale:1,cancellation:cancellation)))
                } else {
                    let image=try LCCProfileBuilder.linearImage(source:source,scale:1)
                    images.append(materialize(applyGain(image,gain:lcc.gainImages[i],scale:1)))
                }
            } else {images.append(try materialize(decoded(source,scale:1,whiteBalance:plan.whiteBalance)))}
        }
        try cancellation.check()
        let scene = composite(plan,images:images,imageScale:1,outputScale:1)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".photons-\(UUID().uuidString).\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at:temp); context.clearCaches() }
        if format == .dng {
            try LinearDNGWriter.write(image:scene,context:context,to:temp,cancellation:cancellation,progress:progress)
        } else {
            progress("写入 16 位 TIFF（LZW）")
            let display=plan.lccState?.protectHighlights == true ? Self.protectedDisplay(scene):scene
            guard let cg = context.createCGImage(display,from:display.extent,format:.RGBA16,
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
