import Foundation
import CoreImage
import PhotonsExtensions

/// A new, demosaiced linear DNG. Never inherits source CFA, crop, lens opcodes or camera matrices:
/// those describe camera samples, whereas these samples are in linear sRGB after stitching.
public enum LinearDNGWriter {
    public static func write(image: CIImage, context: CIContext, to url: URL,
                             cancellation: PanoramaCancellation = .init(),
                             progress: PanoramaEngine.Progress = { _ in }) throws {
        let width = Int(image.extent.width), height = Int(image.extent.height), tile = 256
        guard width>0, height>0, width*height<600_000_000 else { throw PanoramaFailure("DNG 尺寸无效") }
        var maximum = [Float](repeating:0,count:4)
        let maxImage = image.applyingFilter("CIAreaMaximum",parameters:["inputExtent":CIVector(cgRect:image.extent)])
        context.render(maxImage,toBitmap:&maximum,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
        // Store highlight headroom, and restore its scene exposure through BaselineExposure.
        let range = Double(max(1,maximum[0],maximum[1],maximum[2]))
        guard range.isFinite else { throw PanoramaFailure("拼接图像含无效像素") }
        let scaled = image.applyingFilter("CIExposureAdjust",parameters:["inputEV":-log2(range)])
        let nx = (width+tile-1)/tile, ny = (height+tile-1)/tile
        var offsets = [UInt32](repeating:0,count:nx*ny), sizes = offsets
        struct Entry { var tag: UInt16; var type: UInt16; var count: Int; var bytes: Data }
        func u16(_ v: UInt16) -> Data { var v = v.littleEndian; return Data(bytes:&v,count:2) }
        func u32(_ v: UInt32) -> Data { var v = v.littleEndian; return Data(bytes:&v,count:4) }
        func rational(_ value: Double) -> Data {
            u32(UInt32(bitPattern:Int32((value*1_000_000).rounded())))+u32(1_000_000)
        }
        var tags: [Entry] = []
        func short(_ t: UInt16, _ v: [UInt16]) { tags.append(Entry(tag:t,type:3,count:v.count,bytes:v.reduce(Data()) { $0+u16($1) })) }
        func long(_ t: UInt16, _ v: [UInt32]) { tags.append(Entry(tag:t,type:4,count:v.count,bytes:v.reduce(Data()) { $0+u32($1) })) }
        func text(_ t: UInt16, _ v: String) { let data = Data((v+"\0").utf8); tags.append(Entry(tag:t,type:2,count:data.count,bytes:data)) }
        func rationals(_ t: UInt16, _ v: [Double], signed: Bool = false) { tags.append(Entry(tag:t,type:signed ? 10:5,count:v.count,bytes:v.reduce(Data()) { $0+rational($1) })) }
        long(254,[0]); long(256,[UInt32(width)]); long(257,[UInt32(height)])
        short(258,[16,16,16]); short(259,[7]); short(262,[34892]); short(274,[1]); short(277,[3]); short(284,[1])
        text(271,"Photons"); text(272,"Photons Linear Panorama"); text(305,"Photons shift panorama")
        short(339,[1,1,1]); long(322,[UInt32(tile)]); long(323,[UInt32(tile)])
        long(324,offsets); long(325,sizes)
        tags.append(Entry(tag:50706,type:1,count:4,bytes:Data([1,4,0,0])))
        tags.append(Entry(tag:50707,type:1,count:4,bytes:Data([1,3,0,0])))
        text(50708,"Photons Linear Panorama")
        long(50717,[65535,65535,65535]); rationals(50714,[0,0,0])
        rationals(50718,[1,1]); long(50719,[0,0]); long(50720,[UInt32(width),UInt32(height)])
        rationals(50721,[3.2404542,-1.5371385,-0.4985314,-0.9692660,1.8760108,0.0415560,0.0556434,-0.2040259,1.0572252],signed:true)
        rationals(50728,[1,1,1]); rationals(50730,[log2(range)],signed:true)
        short(50778,[21]); long(50829,[0,0,UInt32(height),UInt32(width)])
        tags.sort { $0.tag < $1.tag }
        func header() -> Data {
            var out = Data([0x49,0x49,42,0])+u32(8)+u16(UInt16(tags.count))
            var payload = Data()
            let payloadOffset = 8+2+tags.count*12+4
            for entry in tags {
                let bytes: Data = entry.tag == 324 ? offsets.reduce(Data()) { $0+u32($1) }
                    : (entry.tag == 325 ? sizes.reduce(Data()) { $0+u32($1) } : entry.bytes)
                out += u16(entry.tag)+u16(entry.type)+u32(UInt32(entry.count))
                if bytes.count <= 4 { out += bytes+Data(repeating:0,count:4-bytes.count) }
                else {
                    out += u32(UInt32(payloadOffset+payload.count)); payload += bytes
                    if payload.count % 2 != 0 { payload.append(0) }
                }
            }
            out += u32(0); out += payload
            return out
        }
        FileManager.default.createFile(atPath:url.path,contents:nil)
        let file = try FileHandle(forWritingTo:url)
        defer { try? file.close() }
        try file.write(contentsOf:header())
        var pixels = [UInt16](repeating:0,count:tile*tile*4)
        for ty in 0..<ny { for tx in 0..<nx {
            try cancellation.check()
            if tx == 0 { progress("无损压缩 DNG \(ty+1)/\(ny)") }
            // Both TIFF and CIContext's bitmap rows are top-first. Bounds, however, use Core
            // Image's lower-left origin. Walk bounds from top to bottom without reversing rows.
            let rect = CGRect(x:tx*tile,y:height-(ty+1)*tile,width:tile,height:tile)
            context.render(scaled,toBitmap:&pixels,rowBytes:tile*8,bounds:rect,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
            var rgb = [UInt16](repeating:0,count:tile*tile*3)
            for y in 0..<tile { for x in 0..<tile {
                let src = (y*tile+x)*4, dst = (y*tile+x)*3
                rgb[dst] = pixels[src]; rgb[dst+1] = pixels[src+1]; rgb[dst+2] = pixels[src+2]
            }}
            let tables = RawLosslessJPEG.buildTables([rgb],width:tile*3,height:tile,components:3)
            let blob = rgb.withUnsafeBufferPointer { RawLosslessJPEG.encode($0,width:tile*3,height:tile,components:3,tables:tables) }
            let position = try file.offset()
            guard position+UInt64(blob.count)<UInt64(UInt32.max) else { throw PanoramaFailure("DNG 超过 4 GB 文件上限，请减少拼接张数。") }
            offsets[ty*nx+tx] = UInt32(position); sizes[ty*nx+tx] = UInt32(blob.count)
            try file.write(contentsOf:Data(blob))
        }}
        try file.seek(toOffset:0); try file.write(contentsOf:header()); try file.synchronize()
    }
}
