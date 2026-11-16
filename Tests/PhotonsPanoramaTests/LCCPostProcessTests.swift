import XCTest
import CoreImage
@testable import PhotonsPanorama

final class LCCPostProcessTests:XCTestCase {
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
