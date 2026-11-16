import XCTest
import CoreImage
import ImageIO
@testable import PhotonsPanorama

final class PanoramaProvenanceTests:XCTestCase {
    func fixture(_ folder:URL) throws->PanoramaPlan {
        let url=folder.appendingPathComponent("B002.tiff")
        let image=CIImage(color:CIColor(red:0.3,green:0.2,blue:0.1)).cropped(to:CGRect(x:0,y:0,width:64,height:32))
        let context=CIContext()
        try context.writeTIFFRepresentation(of:image,to:url,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
        let source=try PanoramaSource(url:url)
        return PanoramaPlan(sources:[source,source],origins:[.zero,CGPoint(x:32,y:0)],size:CGSize(width:96,height:32),registrationScores:[1,1],whiteBalance:nil,
            gains:[1,1],ownership:[0,1],maskWidth:2,maskHeight:1,optical:.init(center:nil,confidence:0,explanation:"",occludedEdges:[]),options:.init(),previewScale:1,previewImages:[image,image],preview:nil)
    }
    func testDNGThumbnailManifestAndSnapshotRoundTrip() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:folder)}
        let plan=try fixture(folder)
        let manifest=PanoramaManifest(plan:plan,profileID:LCCLensProfile.builtInID,profileName:"43XL",offsetMM:CGPoint(x:2,y:3),sensor:.init(width:43.8,height:32.9,source:"test"))
        let snapshot=try JSONDecoder().decode(PanoramaSnapshot.self,from:JSONEncoder().encode(PanoramaSnapshot(plan:plan)))
        let frozen=try snapshot.plan();XCTAssertEqual(frozen.origins,plan.origins);XCTAssertEqual(frozen.ownership,plan.ownership)
        let engine=PanoramaEngine(),scene=try engine.renderComposite(frozen),url=folder.appendingPathComponent("result.dng")
        try LinearDNGWriter.write(image:scene,context:CIContext(),to:url,manifest:manifest.encoded())
        let source=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let thumb=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageIfAbsent:false,kCGImageSourceThumbnailMaxPixelSize:512] as CFDictionary)
        XCTAssertNotNil(thumb,"A real embedded thumbnail must be readable without RAW development")
        let read=try XCTUnwrap(PanoramaManifest.read(from:url));XCTAssertEqual(read.frames.count,2)
        XCTAssertEqual(read.profileName,"43XL");XCTAssertFalse(read.correctionApplied)
        XCTAssertEqual(read.canvasPoint(u:0.75,v:0.5),manifest.canvasPoint(u:0.75,v:0.5))
        XCTAssertFalse(String(data:try read.encoded(),encoding:.utf8)!.contains(folder.path))
        XCTAssertEqual(PanoramaManifest.defaultName([URL(fileURLWithPath:"/a/B10.3FR"),URL(fileURLWithPath:"/b/B2.3FR")]),"B2_pano")
    }
}
