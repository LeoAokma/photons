import Foundation
import CoreGraphics

/// Translation-only registration: corner descriptors, a robust displacement vote, then subpixel
/// normalized correlation. No rotation, scale or perspective degrees of freedom exist here.
enum TranslationRegistration {
    struct Match { var offset: CGPoint; var score: Double; var inliers: Int }
    private struct Corner { let x: Int; let y: Int; let strength: Double; let descriptor: [Double] }

    private static func corners(_ image: GrayRaster) -> [Corner] {
        let w = image.width, h = image.height
        guard w > 24, h > 24 else { return [] }
        var candidates: [(Int, Int, Double)] = []
        for y in stride(from: 10, to: h-10, by: 2) {
            for x in stride(from: 10, to: w-10, by: 2) {
                var xx = 0.0, yy = 0.0, xy = 0.0
                for dy in -1...1 { for dx in -1...1 {
                    let p = (y+dy)*w+x+dx
                    let gx = image.values[p+1] - image.values[p-1]
                    let gy = image.values[p+w] - image.values[p-w]
                    xx += gx*gx; yy += gy*gy; xy += gx*gy
                }}
                let score = (xx+yy-sqrt((xx-yy)*(xx-yy)+4*xy*xy)) * 0.5
                if score > 0.00008 { candidates.append((x,y,score)) }
            }
        }
        candidates.sort { $0.2 > $1.2 }
        var blocked = [Bool](repeating: false, count: w*h), result: [Corner] = []
        for (x,y,strength) in candidates where !blocked[y*w+x] {
            var descriptor: [Double] = []
            for dy in stride(from: -8, through: 8, by: 2) { for dx in stride(from: -8, through: 8, by: 2) {
                descriptor.append(image.values[(y+dy)*w+x+dx])
            }}
            let mean = descriptor.reduce(0,+) / Double(descriptor.count)
            let norm = sqrt(descriptor.reduce(0) { $0+($1-mean)*($1-mean) })
            if norm < 0.015 { continue }
            descriptor = descriptor.map { ($0-mean)/norm }
            result.append(Corner(x:x,y:y,strength:strength,descriptor:descriptor))
            for yy in max(0,y-8)...min(h-1,y+8) { for xx in max(0,x-8)...min(w-1,x+8) { blocked[yy*w+xx] = true }}
            if result.count >= 900 { break }
        }
        return result
    }

    static func align(_ a: GrayRaster, _ b: GrayRaster, cancellation: PanoramaCancellation) throws -> Match? {
        let ac = corners(a), bc = corners(b)
        var offsets: [CGPoint] = []
        for (idx, point) in ac.enumerated() {
            if idx % 50 == 0 { try cancellation.check() }
            var best = 10.0, next = 10.0, winner: Corner?
            for other in bc {
                var distance = 0.0
                for k in point.descriptor.indices {
                    let d = point.descriptor[k]-other.descriptor[k]; distance += d*d
                }
                if distance < best { next = best; best = distance; winner = other }
                else if distance < next { next = distance }
            }
            if best < 0.5, best < next * 0.78, let winner {
                offsets.append(CGPoint(x:point.x-winner.x,y:point.y-winner.y))
            }
        }
        var cluster: [CGPoint] = []
        for seed in offsets {
            let near = offsets.filter { hypot($0.x-seed.x,$0.y-seed.y) < 4 }
            if near.count > cluster.count { cluster = near }
        }
        guard cluster.count >= 5 else { return nil }
        let initial = CGPoint(x:median(cluster.map { Double($0.x) }), y:median(cluster.map { Double($0.y) }))
        let refined = refine(a,b,offset:initial,radius:3)
        guard refined.score > 0.72 else { return nil }
        return Match(offset:refined.offset,score:refined.score,inliers:cluster.count)
    }

    /// NCC of gradients suppresses exposure differences and low-frequency lens shading. The
    /// overlap is sampled on a fixed grid to avoid a changing objective during subpixel fitting.
    static func correlation(_ a: GrayRaster, _ b: GrayRaster, offset: CGPoint) -> Double {
        let left = max(3,Int(ceil(offset.x))+3), bottom = max(3,Int(ceil(offset.y))+3)
        let right = min(a.width-3,Int(floor(offset.x))+b.width-3)
        let top = min(a.height-3,Int(floor(offset.y))+b.height-3)
        guard right-left > 20, top-bottom > 20 else { return -1 }
        let step = max(2, Int(sqrt(Double((right-left)*(top-bottom))/6000)))
        var aa = 0.0, bb = 0.0, ab = 0.0, count = 0
        for y in stride(from:bottom,to:top,by:step) { for x in stride(from:left,to:right,by:step) {
            let ax = Double(x), ay = Double(y), bx = ax-offset.x, by = ay-offset.y
            let gx = a.sample(ax+1,ay)-a.sample(ax-1,ay), gy = a.sample(ax,ay+1)-a.sample(ax,ay-1)
            let hx = b.sample(bx+1,by)-b.sample(bx-1,by), hy = b.sample(bx,by+1)-b.sample(bx,by-1)
            aa += gx*gx+gy*gy; bb += hx*hx+hy*hy; ab += gx*hx+gy*hy; count += 1
        }}
        guard aa > 1e-5, bb > 1e-5, count > 80 else { return -1 }
        return ab/sqrt(aa*bb)
    }

    static func refine(_ a: GrayRaster, _ b: GrayRaster, offset: CGPoint, radius: Int) -> Match {
        var best = offset, score = correlation(a,b,offset:offset)
        for dy in -radius...radius { for dx in -radius...radius {
            let p = CGPoint(x:offset.x+Double(dx),y:offset.y+Double(dy))
            let s = correlation(a,b,offset:p)
            if s > score { best = p; score = s }
        }}
        for step in [0.5,0.25,0.125,0.0625] {
            let center = best
            for dy in -1...1 { for dx in -1...1 {
                let p = CGPoint(x:center.x+Double(dx)*step,y:center.y+Double(dy)*step)
                let s = correlation(a,b,offset:p)
                if s > score { best = p; score = s }
            }}
        }
        return Match(offset:best,score:score,inliers:0)
    }
}
