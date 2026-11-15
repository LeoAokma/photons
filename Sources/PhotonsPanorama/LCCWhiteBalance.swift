import Foundation
import CoreImage

/// A shared linear color transform from the calibration white balance to the mean RAW WB.
/// Fit from paired native decodes before any LCC gains. This retains the camera's color matrix
/// rather than approximating its tint/temperature behavior with independent RGB multipliers.
public struct LCCWhiteBalanceTransform {
    var rows:[SIMD3<Double>]=[SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1)]
    public init() {}
    static func fit(_ samples:[(SIMD3<Double>,SIMD3<Double>)])->Self {
        guard samples.count>=12 else {return Self()}
        var normal=[[Double]](repeating:[Double](repeating:0,count:6),count:3)
        for (a,b) in samples {
            for i in 0..<3 {
                for j in 0..<3 {normal[i][j] += a[i]*a[j];normal[i][3+j] += a[i]*b[j]}
            }
        }
        let ridge=max(1e-9,(normal[0][0]+normal[1][1]+normal[2][2])*1e-6)
        for i in 0..<3 {normal[i][i] += ridge;normal[i][3+i] += ridge}
        for k in 0..<3 {
            let pivot=(k..<3).max {abs(normal[$0][k])<abs(normal[$1][k])}!
            normal.swapAt(k,pivot)
            let d=normal[k][k];guard abs(d)>1e-12 else {return Self()}
            for j in k..<6 {normal[k][j] /= d}
            for i in 0..<3 where i != k {let f=normal[i][k];for j in k..<6 {normal[i][j] -= f*normal[k][j]}}
        }
        var result=Self()
        for c in 0..<3 {result.rows[c]=SIMD3(normal[0][3+c],normal[1][3+c],normal[2][3+c])}
        guard result.rows.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && max(abs($0.x),abs($0.y),abs($0.z))<8}) else {return Self()}
        return result
    }
    func applying(to image:CIImage)->CIImage {
        func vector(_ r:SIMD3<Double>)->CIVector {CIVector(x:r.x,y:r.y,z:r.z,w:0)}
        return image.applyingFilter("CIColorMatrix",parameters:["inputRVector":vector(rows[0]),"inputGVector":vector(rows[1]),"inputBVector":vector(rows[2]),"inputAVector":CIVector(x:0,y:0,z:0,w:1)])
    }
}
