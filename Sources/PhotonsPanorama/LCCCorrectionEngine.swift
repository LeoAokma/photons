import PhotonsLocalization
import Foundation
import CoreImage

/// Both standalone correction modes share the panorama's RAW calibration pipeline.
public enum LCCCorrectionEngine {
    public static func traditional(scene:PanoramaSource,flatURL:URL,cancellation:PanoramaCancellation = .init(),
                                   progress:PanoramaEngine.Progress = {_ in}) throws->PanoramaPlan {
        let flat=try PanoramaSource(url:flatURL)
        if let issue=LCCInspector.incompatibility(scene:scene,flat:flat) {throw PanoramaFailure(issue)}
        guard let sensor=scene.sensor else {throw PanoramaFailure(L10n.tr("a56bfaee063f"))}
        var frame=try LCCCreationFrame(url:flatURL);frame.shiftX=0;frame.shiftY=0;frame.shiftConfirmed=true
        let profile=try LCCProfileBuilder.create(name:"LCC · "+flatURL.lastPathComponent,aperture:nil,notes:"Strict one-to-one flat-field correction",frames:[frame],
            sensorLongEdge:max(sensor.width,sensor.height),sensorShortEdge:min(sensor.width,sensor.height),cancellation:cancellation,progress:progress)
        return try single(scene:scene,profile:profile,position:.zero,refine:false,cancellation:cancellation,progress:progress).plan
    }
    public static func fields(_ profile:LCCLensProfile,cancellation:PanoramaCancellation = .init()) throws->[LCCCaptureOrientation:LCCCorrectionField] {
        var fields:[LCCCaptureOrientation:LCCCorrectionField]=[:]
        for orientation in profile.orientations {fields[orientation]=try LCCCorrectionField(profile:profile,orientation:orientation,cancellation:cancellation)}
        return fields
    }
    public static func single(scene:PanoramaSource,profile:LCCLensProfile,position:CGPoint,refine:Bool,
                              body:PanoramaCameraBody = .alpa12Max,orientation:PanoramaBodyOrientation = .degrees0,
                              cancellation:PanoramaCancellation = .init(),progress:PanoramaEngine.Progress = {_ in}) throws->(plan:PanoramaPlan,position:CGPoint) {
        guard let sensor=scene.sensor else {throw PanoramaFailure(L10n.tr("2b2e356aa95e"))}
        guard position.x.isFinite,position.y.isFinite else {throw PanoramaFailure(L10n.tr("9d273dbe67b9"))}
        let engine=PanoramaEngine(),fields=try fields(profile,cancellation:cancellation)
        let plan=try engine.prepareLCCImages(engine.singlePhoto(scene,cancellation:cancellation),cancellation:cancellation,progress:progress)
        var offset=CGPoint(x:-position.x,y:-position.y)
        if refine {
            offset=try LCCPositionSolver.solve(plan:plan,fields:fields,sensor:sensor,cameraBody:body,bodyOrientation:orientation,
                allowPairedFlats:false,approximateOffset:offset,searchRadius:3,cancellation:cancellation,progress:progress).offsetMM
        }
        let corrected=try engine.applyingLCC(plan,profile:profile,fields:fields,offsetMM:offset,sensor:sensor,crop:false,
            cancellation:cancellation,rebuildSeams:false,protectHighlights:false,whiteBalanceOverride:plan.whiteBalance,cameraBody:body,bodyOrientation:orientation)
        return (corrected,CGPoint(x:-offset.x,y:-offset.y))
    }
    /// Rendered images have lost their original camera channels. Use measured rendered-RGB
    /// fields, never misinterpret a CFA map as an RGB map. Recorded blend weights handle mixed
    /// orientations; normalized canvas/crop coordinates survive output resizing.
    public static func postProcess(scene:PanoramaSource,manifest original:PanoramaManifest,profile:LCCLensProfile,
                                   offset:CGPoint? = nil,cancellation:PanoramaCancellation = .init(),
                                   progress:PanoramaEngine.Progress = {_ in}) throws->(plan:PanoramaPlan,manifest:PanoramaManifest) {
        try original.validate()
        guard original.geometryUnrecoverable != true else {throw PanoramaFailure(L10n.tr("fc7ac1c0b0ab"))}
        guard !original.correctionApplied else {throw PanoramaFailure(L10n.tr("edbde7a1e03c"))}
        var rendered=profile
        rendered.captures=try profile.captures.map { capture in
            var c=capture
            guard let grid=c.renderGrid else {throw PanoramaFailure(L10n.tr("630c0e121a40"))}
            c.grid=grid;return c
        }
        let fields=try fields(rendered,cancellation:cancellation),engine=PanoramaEngine()
        var plan=try engine.singlePhoto(scene,cancellation:cancellation)
        let w=512,h=max(2,Int(512*scene.size.height/scene.size.width))
        guard h<=2048 else {throw PanoramaFailure(L10n.tr("759292c5a6ab"))}
        let chosenOffset=offset ?? original.profileOffsetMM
        guard chosenOffset != nil || original.frames.allSatisfy({$0.shiftMM != nil}) else {
            throw PanoramaFailure(L10n.tr("0fb1925587ba"))
        }
        let calibrations=try original.frames.map {frame -> LCCCorrectionField in
            guard LCCProfileSummary.cameraKey(frame.camera)==LCCProfileSummary.cameraKey(profile.camera),
                  let orientation=LCCCaptureOrientation(rawValue:frame.orientation),
                  let field=fields[orientation.relative(to:original.bodyOrientation)] else {throw PanoramaFailure(L10n.tr("f397a44809b0"))}
            return field
        }
        var values=[Float](repeating:1,count:w*h*4),uncovered=0
        for y in 0..<h {
            try cancellation.check();if y%32==0 {progress(L10n.tr("f8cd32a1d0e0" , String(describing: (y)), String(describing: (h))))}
            for x in 0..<w {
                let point=original.canvasPoint(u:(Double(x)+0.5)/Double(w),v:(Double(y)+0.5)/Double(h))
                guard point.x.isFinite,point.y.isFinite,(0...1).contains(point.x),(0...1).contains(point.y) else {continue}
                let mx=min(original.maskWidth-1,max(0,Int(point.x*Double(original.maskWidth))))
                let my=min(original.maskHeight-1,max(0,Int(point.y*Double(original.maskHeight))))
                var sum=SIMD3<Double>.zero,total=0.0,missing=false
                for (i,frame) in original.frames.enumerated() {
                    let weight=Double(original.weights[i][my*original.maskWidth+mx])/255
                    guard weight>0.001 else {continue}
                    guard let sensor=frame.sensor else {throw PanoramaFailure(L10n.tr("e184fba3ced0"))}
                    let rect=frame.sensorRect ?? frame.rect
                    let local=frame.imageToCanvas?.inverse?.point(point) ?? CGPoint(x:(point.x-rect.minX)/rect.width,y:(point.y-rect.minY)/rect.height)
                    let unwarped=CGPoint(x:rect.minX+local.x*rect.width,y:rect.minY+local.y*rect.height)
                    let physical:CGPoint
                    if let chosenOffset {
                        physical=CGPoint(x:(unwarped.x-0.5)*sensor.width/rect.width-chosenOffset.x,
                                         y:(0.5-unwarped.y)*sensor.height/rect.height-chosenOffset.y)
                    } else {
                        let shift=frame.shiftMM!
                        physical=CGPoint(x:shift.x+(local.x-0.5)*sensor.width,
                                         y:shift.y+(0.5-local.y)*sensor.height)
                    }
                    if let g=calibrations[i].gain(at:original.bodyOrientation.inverse.rotate(physical)) {sum += g*weight;total += weight}
                    else {missing=true}
                }
                if total>0 && !missing {
                    let gain=sum/total,o=(y*w+x)*4
                    values[o]=Float(gain.x);values[o+1]=Float(gain.y);values[o+2]=Float(gain.z)
                } else {uncovered += 1}
            }
        }
        guard Double(uncovered)<Double(w*h)*0.01 else {throw PanoramaFailure(L10n.tr("511abfcff05c"))}
        let image=CIImage(bitmapData:values.withUnsafeBytes {Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
            .transformed(by:CGAffineTransform(scaleX:scene.size.width/Double(w),y:scene.size.height/Double(h)))
        let sensor=original.frames.first!.sensor!
        plan.lccState=PanoramaLCCState(profileID:profile.id,profileName:profile.name,offsetMM:chosenOffset ?? .zero,
            gainImages:[image],usesFixedDecode:[true],complete:true,coveredFraction:1,suggestedCropRect:nil,cropRect:nil,footprintRects:[],sensor:sensor,
            exposureEV:0,protectHighlights:false)
        plan.previewImages=[engine.applyGain(plan.previewImages[0],gain:image,scale:plan.previewScale)]
        engine.renderPreview(&plan)
        var manifest=original;manifest.profileID=profile.id;manifest.profileName=profile.name
        manifest.profileOffsetMM=chosenOffset;manifest.correctionApplied=true;manifest.correctionMethod="rendered-rgb-post-correction"
        return (plan,manifest)
    }
}
