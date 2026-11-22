import SwiftUI
import PhotonsPanorama
import PhotonsLocalization

/// One placement diagram for both stitching and profile correction of exported panoramas.
struct CapturePositionDiagram:View {
    struct Frame {
        let name:String
        let center:CGPoint
        let sensor:SensorSize
        var sourceIndex:Int? = nil
        var reading: String? = nil
    }
    let frames:[Frame]
    let cameraBody:PanoramaCameraBody
    let orientation:PanoramaBodyOrientation
    let absolute:Bool
    var selected:Int?
    var showsTravel=true
    var numbered = false
    var anchoredX = false
    var anchoredY = false
    var onMove: ((Int, CGPoint, CGPoint) -> Void)?
    let onSelect:(Int)->Void
    struct DraggedFrame {
        let index: Int
        let start: CGPoint
        let end: CGPoint
        let delta: CGSize
    }
    @GestureState private var drag: DraggedFrame?
    private static let colors:[Color]=[.cyan,.purple,.green,.pink,.yellow,.blue]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }

    // Equal readings can put several frames at exactly the same position. Keep the
    // outlines there and separate just their badges, with the same targets for taps.
    static func badgeCenters(_ photos: [CGRect]) -> [CGPoint] {
        var points = photos.map { CGPoint(x: $0.midX, y: $0.midY) }
        var remaining = Array(points.indices)
        while let first = remaining.first {
            let group = remaining.filter { hypot(points[$0].x - points[first].x, points[$0].y - points[first].y) < 22 }
            remaining.removeAll { group.contains($0) }
            for (slot, index) in group.enumerated() {
                let count = min(4, group.count - slot / 4 * 4)
                points[index].x += (CGFloat(slot % 4) - CGFloat(count - 1) / 2) * 20
                points[index].y += (CGFloat(slot / 4) - CGFloat((group.count - 1) / 4) / 2) * 20
            }
        }
        return points
    }
    private func layout(_ size:CGSize)->(photos:[CGRect],travel:CGRect?) {
        let photos=frames.map {CGRect(x:$0.center.x-$0.sensor.width/2,y:-$0.center.y-$0.sensor.height/2,width:$0.sensor.width,height:$0.sensor.height)}
        let travel=showsTravel ? frames.first.map { frame in
            let range = cameraBody.travel(at: orientation)
            var box = range.coverage(sensor: frame.sensor, centered: !absolute)
            let anchored = range.coverage(sensor: frame.sensor, centered: false)
            if anchoredX { box.origin.x = anchored.minX }
            if anchoredY { box.origin.y = anchored.minY }
            return box
        } : nil
        var bounds=photos.reduce(CGRect.null) {$0.union($1)}
        if let travel {bounds=bounds.union(travel)}
        guard !bounds.isNull,bounds.width>0,bounds.height>0 else {return ([],nil)}
        let scale=min((size.width-28)/bounds.width,(size.height-40)/bounds.height)
        let dx=(size.width-bounds.width*scale)/2-bounds.minX*scale
        let dy=(size.height-bounds.height*scale)/2-bounds.minY*scale+4
        func display(_ r:CGRect)->CGRect {CGRect(x:r.minX*scale+dx,y:r.minY*scale+dy,width:r.width*scale,height:r.height*scale)}
        return (photos.map(display),travel.map(display))
    }
    private func target(at p: CGPoint, photos: [CGRect], badges: [CGPoint]) -> Int? {
        func distance(_ center: CGPoint) -> CGFloat { hypot(p.x-center.x, p.y-center.y) }
        if let i = badges.indices.min(by: { distance(badges[$0]) < distance(badges[$1]) }),
           distance(badges[i]) <= 11 { return i }
        return photos.indices.filter { photos[$0].contains(p) }.min { a,b in
            distance(CGPoint(x: photos[a].midX, y: photos[a].midY)) < distance(CGPoint(x: photos[b].midX, y: photos[b].midY))
        }
    }

    func draggedFrame(at location: CGPoint, translation: CGSize, photos: [CGRect], badges: [CGPoint]) -> DraggedFrame? {
        guard onMove != nil, let index = target(at: location, photos: photos, badges: badges) else { return nil }
        let frame = frames[index], scale = photos[index].width / frame.sensor.width
        guard scale.isFinite, scale > 0 else { return nil }
        let start = frame.center, travel = cameraBody.travel(at: orientation)
        var end = travel.dragged(start, translation: translation, pointsPerMM: scale)
        // Minor cross-axis mouse jitter must not replace an unknown or symbolic end-stop reading.
        if abs(translation.width) < 2 { end.x = start.x }
        if abs(translation.height) < 2 { end.y = start.y }
        return DraggedFrame(index: index, start: start, end: end,
                            delta: CGSize(width: (end.x-start.x)*scale, height: (start.y-end.y)*scale))
    }

    private func gesture(photos: [CGRect], badges: [CGPoint]) -> some Gesture {
        let move = DragGesture(minimumDistance: 3)
            .updating($drag) { value, state, transaction in
                transaction.animation = nil
                state = draggedFrame(at: value.startLocation, translation: value.translation, photos: photos, badges: badges)
            }
            .onEnded { value in
                guard let result = draggedFrame(at: value.startLocation, translation: value.translation, photos: photos, badges: badges),
                      result.start != result.end else { return }
                onMove?(frames[result.index].sourceIndex ?? result.index, result.start, result.end)
            }
        let click = SpatialTapGesture().onEnded { event in
            if let i = target(at: event.location, photos: photos, badges: badges) { onSelect(frames[i].sourceIndex ?? i) }
        }
        return move.exclusively(before: click)
    }

    var body:some View {
        GeometryReader {proxy in
            let placement=layout(proxy.size)
            let original = placement.photos
            let originalBadges = numbered ? Self.badgeCenters(original) : []
            let photos = original.indices.map { i in
                if let drag, drag.index == i { return original[i].offsetBy(dx: drag.delta.width, dy: drag.delta.height) }
                return original[i]
            }
            let badges = drag == nil ? originalBadges : (numbered ? Self.badgeCenters(photos) : [])
            Canvas {context,size in
                if let travel=placement.travel {
                    context.stroke(Path(travel),with:.color(.primary.opacity(0.65)),style:StrokeStyle(lineWidth:1.2,dash:[5,3]))
                    context.draw(Text(L10n.tr("fe8af84b5fd4",cameraBody.name,String(orientation.rawValue))).font(.system(size:9)).foregroundColor(.secondary),at:CGPoint(x:travel.midX,y:travel.minY-9))
                }
                for i in photos.indices {
                    let rect=photos[i],frame=frames[i],color=Self.color(i)
                    let center = drag?.index == i ? (drag?.end ?? frame.center) : frame.center
                    let outside=absolute && showsTravel && !cameraBody.travel(at:orientation).contains(center)
                    context.fill(Path(rect),with:.color(color.opacity(0.14)))
                    context.stroke(Path(rect),with:.color(outside ? .orange:color),lineWidth:selected==(frame.sourceIndex ?? i) || drag?.index == i ? 2.5:1.2)
                    if numbered { continue }
                    context.draw(Text(frame.name).font(.system(size:10,weight:.medium)),at:CGPoint(x:rect.midX,y:rect.midY))
                    if showsTravel {
                        let text=String(format:absolute ? "X %+.1f · Y %+.1f mm":"Δ %+.1f, %+.1f mm",center.x,center.y)
                        context.draw(Text(text).font(.system(size:8)).foregroundColor(.secondary),at:CGPoint(x:rect.midX,y:rect.midY+13))
                    }
                }
                for (i, p) in badges.enumerated() {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(Self.color(i)))
                    context.draw(Text(String(i+1)).font(.system(size:10,weight:.bold)).foregroundColor(.black), at: p)
                }
                // A common reading belongs to the whole stack of coincident photos.
                var captions: [CGRect] = []
                for i in badges.indices {
                    let caption: String?
                    if let drag, drag.index == i {
                        caption = [drag.start.x != drag.end.x ? String(format: "X %+.1f", drag.end.x) : nil,
                                   drag.start.y != drag.end.y ? String(format: "Y %+.1f", drag.end.y) : nil]
                            .compactMap { $0 }.joined(separator: " · ")
                    } else { caption = frames[i].reading }
                    guard let reading = caption else { continue }
                    let rect = photos[i]
                    let label = context.resolve(Text(reading).font(.system(size: 9, weight: .medium)))
                    let extent = label.measure(in: size)
                    let box = CGRect(x: rect.midX - extent.width / 2, y: badges[i].y + 11,
                                     width: extent.width, height: extent.height)
                    guard !captions.contains(where: { $0.intersects(box) }) else { continue }
                    context.draw(label, in: box)
                    captions.append(box)
                }
                if !absolute && !numbered {context.draw(Text(L10n.tr("00964853f102")).font(.system(size:8)).foregroundColor(.secondary),at:CGPoint(x:size.width/2,y:size.height-8))}
            }.contentShape(Rectangle()).gesture(gesture(photos: original, badges: originalBadges))
        }.accessibilityIdentifier("lcc.placementDiagram")
    }
}
