import Foundation
import CoreGraphics

/// Translation-only registration: corner descriptors, a robust displacement vote, then subpixel
/// normalized correlation. No rotation, scale or perspective degrees of freedom exist here.
enum TranslationRegistration {
    struct Match {
        var offset: CGPoint
        var score: Double
        var inliers: Int
        var anchors: [CGPoint] = []
        // A handful of votes along a single wire can all select the same wrong displacement.
        // Require support wider than one descriptor when evidence is sparse.
        var hasIndependentSupport: Bool {
            guard inliers < 10 else { return true }
            guard let first = anchors.first else { return false }
            let bounds = anchors.dropFirst().reduce(CGRect(origin: first, size: .zero)) { box, p in
                box.union(CGRect(origin: p, size: .zero))
            }
            return min(bounds.width, bounds.height) >= 16
        }
    }
    struct Edge {
        let a: Int
        let b: Int
        let offset: CGPoint
        let score: Double
    }

    /// Reconcile only small disagreements between image-measured loops, in native pixels.
    static func consistentOrigins(_ tree: [CGPoint], edges: [Edge], tolerance: Double) -> [CGPoint]? {
        func residual(_ origins: [CGPoint], _ edge: Edge) -> Double {
            hypot(origins[edge.b].x - origins[edge.a].x - edge.offset.x,
                  origins[edge.b].y - origins[edge.a].y - edge.offset.y)
        }
        let worst = edges.lazy.filter { $0.score > 0.8 }.map { residual(tree, $0) }.max() ?? 0
        if worst <= tolerance { return tree }
        // Two placements each within tolerance can differ by up to twice that distance.
        // Larger disagreements require different image evidence or a different geometry.
        guard worst <= 2 * tolerance, edges.count >= tree.count else { return nil }
        var rows: [[Double]] = [], xs: [Double] = [], ys: [Double] = []
        for edge in edges {
            let weight = sqrt(edge.score)
            var row = [Double](repeating: 0, count: tree.count - 1)
            if edge.a > 0 { row[edge.a - 1] = -weight }
            if edge.b > 0 { row[edge.b - 1] = weight }
            rows.append(row)
            xs.append(weight * edge.offset.x)
            ys.append(weight * edge.offset.y)
        }
        guard let x = leastSquares(rows, xs), let y = leastSquares(rows, ys) else { return nil }
        let fitted = [tree[0]] + x.indices.map { CGPoint(x: tree[0].x + x[$0], y: tree[0].y + y[$0]) }
        return edges.allSatisfy { residual(fitted, $0) <= tolerance } ? fitted : nil
    }

    private struct Corner { let x: Int; let y: Int; let strength: Double; let descriptor: [Double] }

    private static func corners(_ image: GrayRaster, distributed: Bool) -> [Corner] {
        let w = image.width, h = image.height
        guard w > 24, h > 24 else { return [] }
        let minimumStrength = distributed ? 0.000008 : 0.00008
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
                if score > minimumStrength { candidates.append((x,y,score)) }
            }
        }
        candidates.sort { $0.2 > $1.2 }
        var blocked = [Bool](repeating: false, count: w*h), result: [Corner] = []
        var occupancy = [Int](repeating: 0, count: 48)
        for (x,y,strength) in candidates where !blocked[y*w+x] {
            let tile = (y*6/h)*8 + x*8/w
            guard !distributed || occupancy[tile] < 20 else {continue}
            var descriptor: [Double] = []
            for dy in stride(from: -8, through: 8, by: 2) { for dx in stride(from: -8, through: 8, by: 2) {
                descriptor.append(image.values[(y+dy)*w+x+dx])
            }}
            let mean = descriptor.reduce(0,+) / Double(descriptor.count)
            let norm = sqrt(descriptor.reduce(0) { $0+($1-mean)*($1-mean) })
            if norm < 0.015 { continue }
            descriptor = descriptor.map { ($0-mean)/norm }
            occupancy[tile] += 1
            result.append(Corner(x:x,y:y,strength:strength,descriptor:descriptor))
            for yy in max(0,y-8)...min(h-1,y+8) { for xx in max(0,x-8)...min(w-1,x+8) { blocked[yy*w+xx] = true }}
            if result.count >= 900 { break }
        }
        return result
    }

    static func correspondences(_ a:GrayRaster,_ b:GrayRaster,distributed:Bool = false, expected: PanoramaShiftPosition = .init(), radius: Double = 0,
                                cancellation:PanoramaCancellation) throws -> [ProjectiveRegistration.Pair] {
        let ac = corners(a,distributed:distributed)
        var bc = corners(b,distributed:distributed)
        let displacement = expected.x ?? expected.y
        func coordinate(_ corner: Corner) -> Int { expected.x != nil ? corner.x : corner.y }
        if displacement != nil {
            guard radius.isFinite, radius >= 0 else { return [] }
            bc.sort { coordinate($0) < coordinate($1) }
        }
        func lowerBound(_ coordinateLimit: Double) -> Int {
            var low = 0, high = bc.count
            while low < high {
                let mid = (low + high) / 2
                if Double(coordinate(bc[mid])) < coordinateLimit { low = mid + 1 } else { high = mid }
            }
            return low
        }
        var pairs: [ProjectiveRegistration.Pair] = []
        for (idx, point) in ac.enumerated() {
            if idx % 50 == 0 {try cancellation.check()}
            var best = 10.0, next = 10.0, winner: Corner?
            var candidates = bc[...]
            if let displacement {
                let center = Double(coordinate(point)) - displacement
                candidates = bc[lowerBound(center - radius)..<lowerBound(floor(center + radius) + 1)]
            }
            for other in candidates {
                if expected.x != nil, let y = expected.y, abs(Double(point.y - other.y) - y) > radius { continue }
                var distance = 0.0
                for k in point.descriptor.indices {
                    let d = point.descriptor[k]-other.descriptor[k]; distance += d*d
                }
                if distance < best { next = best; best = distance; winner = other }
                else if distance < next { next = distance }
            }
            if best < 0.5, best < next * 0.78, let winner {
                pairs.append(.init(a:CGPoint(x:point.x,y:point.y),b:CGPoint(x:winner.x,y:winner.y)))
            }
        }
        return pairs
    }

    /// Corner coordinates are integers. In the open four-pixel disk each row spans
    /// x ± 3, except the outermost rows (y ± 3), which span x ± 2.
    static func consensusIndices(_ offsets: [SIMD2<Int>]) -> [Int] {
        guard !offsets.isEmpty else { return [] }
        let rows = Dictionary(grouping: offsets.indices) { offsets[$0].y }
            .mapValues { $0.sorted { offsets[$0].x < offsets[$1].x } }
        var votes = [Int](repeating: 0, count: offsets.count)
        for (y, seeds) in rows {
            for dy in -3...3 {
                guard let neighbors = rows[y + dy] else { continue }
                let radius = abs(dy) == 3 ? 2 : 3
                var left = 0, right = 0
                for seed in seeds {
                    let x = offsets[seed].x
                    while left < neighbors.count, offsets[neighbors[left]].x < x - radius { left += 1 }
                    while right < neighbors.count, offsets[neighbors[right]].x <= x + radius { right += 1 }
                    votes[seed] += right - left
                }
            }
        }
        var winner = 0
        for index in votes.indices where votes[index] > votes[winner] { winner = index }
        return offsets.indices.filter { index in
            let delta = offsets[index] &- offsets[winner]
            return abs(delta.y) <= 3 && abs(delta.x) <= (abs(delta.y) == 3 ? 2 : 3)
        }
    }

    static func align(_ a: GrayRaster, _ b: GrayRaster, cancellation: PanoramaCancellation) throws -> Match? {
        guard let match = try featureMatch(a,b,distributed:false,cancellation:cancellation) else {return nil}
        if match.hasIndependentSupport { return match }
        // In the retry, reserve descriptors for quieter parts of the overlap.
        guard let verified = try featureMatch(a,b,distributed:true,cancellation:cancellation),
              verified.hasIndependentSupport else {return nil}
        return verified
    }

    private static func featureMatch(_ a: GrayRaster, _ b: GrayRaster, distributed: Bool, expected: PanoramaShiftPosition = .init(), radius: Double = 0,
                                     cancellation: PanoramaCancellation) throws -> Match? {
        let pairs = try correspondences(a,b,distributed:distributed,expected:expected,radius:radius,cancellation:cancellation)
        guard pairs.count >= 5 else { return nil }
        let offsets = pairs.map { SIMD2(Int($0.a.x - $0.b.x), Int($0.a.y - $0.b.y)) }
        let cluster = consensusIndices(offsets)
        guard cluster.count >= 5 else { return nil }
        let initial = CGPoint(x: median(cluster.map { Double(offsets[$0].x) }),
                              y: median(cluster.map { Double(offsets[$0].y) }))
        let anchors = stride(from: 0, to: cluster.count, by: max(1, cluster.count / 64)).map { pairs[cluster[$0]].a }
        let refined = refine(a,b,offset:initial,radius:3,anchors:anchors)
        guard refined.score > 0.72 else { return nil }
        return Match(offset:refined.offset,score:refined.score,inliers:cluster.count,anchors:anchors)
    }

    static func align(_ a: GrayRaster, _ b: GrayRaster, expected: PanoramaShiftPosition,
                      radius: Double, cancellation: PanoramaCancellation) throws -> Match? {
        guard expected.x != nil || expected.y != nil else { return try align(a, b, cancellation: cancellation) }
        // Search a strip when only one displacement is known. Verify with image evidence across
        // the overlap before accepting a restricted match, since the scale reading can be wrong.
        for distributed in [false, true] {
            if let guided = try featureMatch(a, b, distributed: distributed, expected: expected, radius: radius,
                                             cancellation: cancellation),
               guided.inliers >= 10, correlation(a, b, offset: guided.offset) > 0.7 {
                return guided
            }
        }
        if let independent = try align(a, b, cancellation: cancellation) { return independent }
        if let point = expected.point {
            return try align(a, b, near: point, radius: radius, cancellation: cancellation)
        }
        return nil
    }

    /// Bounded image search around measured shift differences. A measurement supplies a
    /// search window, never a successful match by itself. The final coordinates remain
    /// subpixel image matches, including when the entered reading is slightly imprecise.
    static func align(_ a:GrayRaster,_ b:GrayRaster,near expected:CGPoint,radius:Double,
                      cancellation:PanoramaCancellation) throws -> Match? {
        guard expected.x.isFinite,expected.y.isFinite,radius.isFinite,radius>0 else {return nil}
        let scale=min(1,256/Double(a.width))
        func small(_ image:GrayRaster)->GrayRaster {
            let w=max(2,Int(Double(image.width)*scale)),h=max(2,Int(Double(image.height)*scale))
            var values=[Double]();values.reserveCapacity(w*h)
            for y in 0..<h {for x in 0..<w {values.append(image.sample(Double(x)/scale,Double(y)/scale))}}
            return GrayRaster(width:w,height:h,values:values)
        }
        try cancellation.check()
        let low=refine(small(a),small(b),offset:CGPoint(x:expected.x*scale,y:expected.y*scale),radius:min(24,max(2,Int(ceil(radius*scale)))))
        try cancellation.check()
        let match=refine(a,b,offset:CGPoint(x:low.offset.x/scale,y:low.offset.y/scale),radius:3)
        guard match.score>0.72,hypot(match.offset.x-expected.x,match.offset.y-expected.y)<=radius+1 else {return nil}
        return match
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

    /// Each verified corner contributes one normalized patch vote. Moving water, sky, or a
    /// single high-contrast foreground object must not dominate the whole overlap's score.
    private static func localCorrelation(_ a: GrayRaster, _ b: GrayRaster, offset: CGPoint, anchors: [CGPoint]) -> Double {
        var scores: [Double] = []
        for p in anchors {
            guard p.x >= 8, p.y >= 8, p.x < Double(a.width-8), p.y < Double(a.height-8),
                  p.x-offset.x >= 8, p.y-offset.y >= 8,
                  p.x-offset.x < Double(b.width-8), p.y-offset.y < Double(b.height-8) else { continue }
            var aa=0.0, bb=0.0, ab=0.0
            for dy in stride(from:-6,through:6,by:3) { for dx in stride(from:-6,through:6,by:3) {
                let x=p.x+Double(dx), y=p.y+Double(dy), u=x-offset.x, v=y-offset.y
                let gx=a.sample(x+1,y)-a.sample(x-1,y), gy=a.sample(x,y+1)-a.sample(x,y-1)
                let hx=b.sample(u+1,v)-b.sample(u-1,v), hy=b.sample(u,v+1)-b.sample(u,v-1)
                aa += gx*gx+gy*gy; bb += hx*hx+hy*hy; ab += gx*hx+gy*hy
            }}
            if aa > 1e-6, bb > 1e-6 { scores.append(ab/sqrt(aa*bb)) }
        }
        guard !scores.isEmpty else { return -1 }
        return median(scores)
    }

    static func refine(_ a: GrayRaster, _ b: GrayRaster, offset: CGPoint, radius: Int, anchors: [CGPoint] = []) -> Match {
        func scoreAt(_ point: CGPoint) -> Double {
            anchors.isEmpty ? correlation(a,b,offset:point) : localCorrelation(a,b,offset:point,anchors:anchors)
        }
        var best = offset, score = scoreAt(offset)
        for dy in -radius...radius { for dx in -radius...radius {
            let p = CGPoint(x:offset.x+Double(dx),y:offset.y+Double(dy))
            let s = scoreAt(p)
            if s > score { best = p; score = s }
        }}
        for step in [0.5,0.25,0.125,0.0625] {
            let center = best
            for dy in -1...1 { for dx in -1...1 {
                let p = CGPoint(x:center.x+Double(dx)*step,y:center.y+Double(dy)*step)
                let s = scoreAt(p)
                if s > score { best = p; score = s }
            }}
        }
        return Match(offset:best,score:score,inliers:0)
    }
}
