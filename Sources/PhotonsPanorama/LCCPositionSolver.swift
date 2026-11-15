import Foundation
import CoreImage

public struct LCCPositionSolution {
    public let offsetMM:CGPoint
    public let explanation:String
    public let flatCount:Int
}

public enum LCCPositionSolver {
    struct Observation {
        let frame:Int
        let point:CGPoint
        let logRGB:SIMD3<Double>
        let field:LCCCorrectionField
    }
    public static func solve(plan:PanoramaPlan,fields:[LCCCaptureOrientation:LCCCorrectionField],sensor:SensorSize,
                             cancellation:PanoramaCancellation = .init(),progress:PanoramaEngine.Progress = {_ in}) throws -> LCCPositionSolution {
        let engine=PanoramaEngine(),records=LCCPairingStore().records()
        var observations:[Observation]=[],flats=0
        let w=plan.sources[0].size.width,h=plan.sources[0].size.height
        let centers=plan.sources.indices.map {i in CGPoint(x:(plan.sourceRect(i).midX-plan.size.width/2)*sensor.width/w,
            y:(plan.size.height/2-plan.sourceRect(i).midY)*sensor.height/h)}
        // The Alpa travel constrains the optical origin, but does not establish its value.
        let x0=centers.map {$0.x-18.75}.max()!,x1=centers.map {$0.x+18.75}.min()!
        let y0=centers.map {$0.y-25.75}.max()!,y1=centers.map {$0.y+18.75}.min()!
        guard x1>=x0,y1>=y0 else {throw PanoramaFailure("拼接范围超过 Alpa 12 Max 行程，无法用该机身约束自动解算。请手动输入位置。")}
        let flatRecords=plan.sources.map {source in records.first {$0.scene.standardizedFileURL==source.url.standardizedFileURL}}
        let useFlats=flatRecords.contains {$0 != nil}
        for i in plan.sources.indices {
            try cancellation.check()
            guard let orientation=LCCCaptureOrientation(rawValue:plan.sources[i].orientation),let field=fields[orientation] else {continue}
            let image:CIImage
            if useFlats {
                guard let pair=flatRecords[i] else {continue}
                progress("读取已配对白板 \(flats+1)…")
                let source=try PanoramaSource(url:pair.flat)
                guard LCCInspector.incompatibility(scene:plan.sources[i],flat:source)==nil else {continue}
                image=try LCCProfileBuilder.linearImage(source:source,scale:256/source.size.width);flats += 1
            } else {
                guard let images=plan.lccLinearPreviewImages else {throw PanoramaFailure("请先准备 LCC 预览。")}
                image=images[i]
            }
            let raster=PanoramaRaster(image:image,context:engine.context,width:48,height:36)
            for yy in 2..<34 {for xx in 2..<46 {
                guard let c=raster.rgb(Double(xx),Double(yy)),min(c.x,c.y,c.z)>0.00005 else {continue}
                let p=CGPoint(x:centers[i].x+(Double(xx)/48-0.5)*sensor.width,
                              y:centers[i].y+(0.5-Double(yy)/36)*sensor.height)
                observations.append(.init(frame:i,point:p,logRGB:SIMD3(log(c.x),log(c.y),log(c.z)),field:field))
            }}
        }
        guard observations.count>100 else {throw PanoramaFailure("可用于位置解算的有效标定与图像不足。请检查方向匹配或手动指定位置。")}
        progress(useFlats ? "用配对白板的红移、暗角匹配镜头 Profile…":"从场景红移、暗角估计中心（低置信度）…")
        let result=try search(observations:observations,xRange:x0...x1,yRange:y0...y1,flat:useFlats,cancellation:cancellation)
        var explanation=useFlats
            ? String(format:"依据 %d 张已配对白板解算；匹配残差 %.1f%%。仍请预览核对。白板仅用于定位，像素校正仍来自镜头 Profile。",flats,result.error*100)
            : "仅依据场景红移与暗角估计，可信度较低：天空、建筑颜色与照明可能干扰，请预览核对，已知机身读数优先。"
        if min(result.point.x-x0,x1-result.point.x,result.point.y-y0,y1-result.point.y)<0.2 {
            explanation += " 候选接近机身行程边界，请以实际读数核对。"
        }
        return LCCPositionSolution(offsetMM:result.point,explanation:explanation,flatCount:flats)
    }
    static func search(observations:[Observation],xRange:ClosedRange<Double>,yRange:ClosedRange<Double>,flat:Bool,
                       cancellation:PanoramaCancellation) throws -> (point:CGPoint,error:Double) {
        func score(_ offset:CGPoint)->Double {
            var groups:[Int:[SIMD3<Double>]]=[:]
            for o in observations {
                guard let g=o.field.gain(at:CGPoint(x:o.point.x-offset.x,y:o.point.y-offset.y)) else {continue}
                let c=o.logRGB+SIMD3(log(g.x),log(g.y),log(g.z))
                groups[o.frame,default:[]].append(SIMD3(c.x-c.y,c.z-c.y,c.y))
            }
            let used=groups.values.reduce(0) {$0+$1.count}
            guard used>observations.count*9/10 else {return .infinity}
            var residuals:[Double]=[]
            for values in groups.values {
                let center=SIMD3(median(values.map(\.x)),median(values.map(\.y)),median(values.map(\.z)))
                for v in values {
                    let d=v-center
                    // Red/green and blue/green carry position information without scene exposure.
                    // Luma is a weaker cue, particularly when the input is not a white plate.
                    residuals.append(sqrt(d.x*d.x+d.y*d.y+(flat ? 0.25:0.04)*d.z*d.z))
                }
            }
            residuals.sort()
            let retained=max(1,Int(Double(residuals.count)*0.85))
            return residuals.prefix(retained).reduce(0,+)/Double(retained)+Double(observations.count-used)/Double(observations.count)*0.5
        }
        var best=CGPoint(x:(xRange.lowerBound+xRange.upperBound)/2,y:(yRange.lowerBound+yRange.upperBound)/2),error=Double.infinity
        for step in [2.0,0.5,0.1] {
            let xr=step==2 ? xRange:max(xRange.lowerBound,best.x-2)...min(xRange.upperBound,best.x+2)
            let yr=step==2 ? yRange:max(yRange.lowerBound,best.y-2)...min(yRange.upperBound,best.y+2)
            let nx=max(1,Int(ceil((xr.upperBound-xr.lowerBound)/step))),ny=max(1,Int(ceil((yr.upperBound-yr.lowerBound)/step)))
            for y in 0...ny {
                try cancellation.check()
                for x in 0...nx {
                    let p=CGPoint(x:xr.lowerBound+Double(x)/Double(nx)*(xr.upperBound-xr.lowerBound),
                                  y:yr.lowerBound+Double(y)/Double(ny)*(yr.upperBound-yr.lowerBound))
                    let e=score(p);if e<error {best=p;error=e}
                }
            }
        }
        guard error.isFinite else {throw PanoramaFailure("Profile 的实测覆盖不足以自动解算当前拼接图，请手动对齐。")}
        return (best,error)
    }
}
