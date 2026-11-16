import XCTest
import CoreImage
@testable import PhotonsPanorama

final class LCCPostProcessTests:XCTestCase {
    func testBostonStandalonePanoramasResolveWithoutManualPosition() throws {
        guard let path=ProcessInfo.processInfo.environment["PHOTONS_LCC_POST_DIR"] else {throw XCTSkip("External panorama fixture")}
        let profileURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/PhotonsPanorama/Profiles/43xl-iiic-cfv100c.photonslcc")
        let profile=try LCCProfileCodec.decode(Data(contentsOf:profileURL))
        for name in ["B0000641_pano.dng","B0000644_pano.dng"] {
            let url=URL(fileURLWithPath:path).appendingPathComponent(name)
            let source=try PanoramaSource(url:url),manifest=try XCTUnwrap(PanoramaManifest.read(from:url))
            XCTAssertNil(manifest.profileOffsetMM)
            XCTAssertFalse(manifest.correctionApplied)
            let solved=try LCCCorrectionEngine.resolvePostProcessPosition(scene:source,manifest:manifest,profile:profile)
            print("BOSTON POST POSITION",name,solved.offsetMM)
            let result=try LCCCorrectionEngine.postProcess(scene:source,manifest:manifest,profile:profile,offset:solved.offsetMM)
            XCTAssertTrue(result.manifest.correctionApplied)
            XCTAssertNotNil(result.plan.preview)
            XCTAssertEqual(result.manifest.frames.count,3)
            XCTAssertTrue(solved.offsetMM.x.isFinite && solved.offsetMM.y.isFinite)
            print("BOSTON POST LCC",name,solved.offsetMM)
        }
    }
    func testAutomaticPostPositionUsesRenderedProfileWithoutOriginalFiles() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let context=CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace])
        let xs=stride(from:-18.0,through:18.0,by:3).map {$0},ys=stride(from:12.0,through:-12.0,by:-3).map {$0}
        var captures:[LCCProfileCapture]=[]
        for cy in [-12.0,0,12] {for cx in [-18.0,0,18] {
            var measured:[Float]=[]
            for y in ys {for x in xs {
                let px=x+cx,py=y+cy
                measured += [Float(exp(-0.0009*px*px-0.0002*py*py)),1,Float(exp(-0.0003*px*px-0.0011*py*py))]
            }}
            let grid=LCCMeasurementGrid(x:xs,y:ys,channels:["R","G","B"],values:LCCMeasurementGrid.pack(measured),space:"apple-linear-srgb-6500K-v1")
            var capture=LCCProfileCapture(id:UUID(),filename:"missing-flat.tiff",orientation:.landscape,shiftX:cx,shiftY:cy,sensorWidth:36,sensorHeight:24,pixelWidth:320,pixelHeight:160,iso:64,exposureSeconds:1,capturedAt:nil,grid:grid,thumbnail:nil)
            capture.renderGrid=grid;captures.append(capture)
        }}
        var profile=LCCLensProfile(id:UUID(),name:"Offline",camera:"",aperture:11,notes:"",createdAt:Date(),captures:captures)
        let field=try LCCCorrectionField(profile:profile,orientation:.landscape),expected=CGPoint(x:3,y:-2)
        let w=320,h=160
        var rgba=[Float](repeating:1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {
            let p=CGPoint(x:((Double(x)+0.5)/Double(w)-0.5)*36-expected.x,y:(0.5-(Double(y)+0.5)/Double(h))*24-expected.y)
            let gain=try XCTUnwrap(field.gain(at:p)),i=(y*w+x)*4
            rgba[i]=Float(0.3/gain.x);rgba[i+1]=Float(0.3/gain.y);rgba[i+2]=Float(0.3/gain.z)
        }}
        let image=CIImage(bitmapData:rgba.withUnsafeBytes {Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
        let url=folder.appendingPathComponent("standalone-pano.tiff")
        try context.writeTIFFRepresentation(of:image,to:url,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
        let source=try PanoramaSource(url:url);profile.camera=source.camera
        var manifest=PanoramaManifest(plan:try PanoramaEngine().singlePhoto(source),sensor:.init(width:36,height:24,source:"fixture"))
        manifest.frames[0].filename="unavailable-original.3FR"
        let solution=try LCCCorrectionEngine.resolvePostProcessPosition(scene:source,manifest:manifest,profile:profile)
        XCTAssertEqual(solution.offsetMM.x,expected.x,accuracy:0.4)
        XCTAssertEqual(solution.offsetMM.y,expected.y,accuracy:0.4)
        let corrected=try LCCCorrectionEngine.postProcess(scene:source,manifest:manifest,profile:profile)
        XCTAssertNotNil(corrected.manifest.profileOffsetMM)
        XCTAssertTrue(corrected.manifest.correctionApplied)
        // A recorded frame position resolves the optical origin directly, without a scene fit.
        manifest.frames[0].shiftMM=CGPoint(x:-expected.x,y:-expected.y)
        let recorded=try LCCCorrectionEngine.resolvePostProcessPosition(scene:source,manifest:manifest,profile:profile)
        XCTAssertEqual(recorded.offsetMM,expected)
        XCTAssertEqual(manifest.position(of:0,offset:expected),manifest.frames[0].shiftMM)
        manifest.crop=CGRect(x:0.2,y:0.1,width:0.6,height:0.8)
        manifest.outputTransform=[0,1,0,-1,0,1,0,0,1]
        let point=manifest.canvasPoint(u:0.3,v:0.6),output=try XCTUnwrap(manifest.outputPoint(canvas:point))
        XCTAssertEqual(output.x,0.3,accuracy:1e-10);XCTAssertEqual(output.y,0.6,accuracy:1e-10)
    }
    func testPostCorrectionIsIndependentOfExportResolutionAndRejectsDoubleCorrection() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let context=CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace])
        func source(_ width:Int)throws->PanoramaSource {
            let url=folder.appendingPathComponent("pano-\(width).tiff")
            let image=CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2)).cropped(to:CGRect(x:0,y:0,width:width,height:width/2))
            try context.writeTIFFRepresentation(of:image,to:url,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
            return try PanoramaSource(url:url)
        }
        let original=try source(640),small=try source(320)
        let plan=try PanoramaEngine().singlePhoto(original)
        let manifest=PanoramaManifest(plan:plan,profileName:"Test",offsetMM:.zero,sensor:.init(width:36,height:24,source:"test"))
        let xs=[-18.0,-9,0,9,18],ys=[12.0,6,0,-6,-12]
        var values:[Float]=[]
        for _ in ys {for x in xs {values += [Float(0.5*(1-0.35*abs(x)/18)),0.5,0.5]}}
        let grid=LCCMeasurementGrid(x:xs,y:ys,channels:["R","G","B"],values:LCCMeasurementGrid.pack(values),space:"apple-linear-srgb-6500K-v1")
        var capture=LCCProfileCapture(id:UUID(),filename:"flat.tiff",orientation:.landscape,shiftX:0,shiftY:0,sensorWidth:36,sensorHeight:24,pixelWidth:640,pixelHeight:320,iso:64,exposureSeconds:1/6,capturedAt:nil,grid:grid,thumbnail:nil)
        capture.renderGrid=grid
        let profile=LCCLensProfile(id:UUID(),name:"Test",camera:original.camera,aperture:11,notes:"",createdAt:Date(),captures:[capture])
        let largeResult=try LCCCorrectionEngine.postProcess(scene:original,manifest:manifest,profile:profile)
        let smallResult=try LCCCorrectionEngine.postProcess(scene:small,manifest:manifest,profile:profile)
        let large=PanoramaRaster(image:try XCTUnwrap(largeResult.plan.lccState?.gainImages.first),context:context,width:64,height:32)
        let reduced=PanoramaRaster(image:try XCTUnwrap(smallResult.plan.lccState?.gainImages.first),context:context,width:64,height:32)
        for i in large.rgba.indices {XCTAssertEqual(large.rgba[i],reduced.rgba[i],accuracy:0.0001)}
        XCTAssertGreaterThan(try XCTUnwrap(large.rgb(3,16)).x,try XCTUnwrap(large.rgb(32,16)).x)
        XCTAssertThrowsError(try LCCCorrectionEngine.postProcess(scene:small,manifest:largeResult.manifest,profile:profile))
    }
}
