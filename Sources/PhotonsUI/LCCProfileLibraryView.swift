import AppKit
import SwiftUI
import PhotonsPanorama

@MainActor
final class LCCProfileLibraryModel: ObservableObject {
    @Published var profiles:[LCCProfileSummary]=[]
    @Published var selected:UUID?
    @Published var profile:LCCLensProfile?
    @Published var status=""
    @Published var busy=false
    @Published var error:String?
    private var creator:LCCProfileCreatorWindowController?
    private let queue=DispatchQueue(label:"Photons.lcc.profile.library",qos:.userInitiated)
    func refresh(select id:UUID? = nil) {
        busy=true
        queue.async { [weak self] in
            do {
                let store=LCCProfileStore();try store.installBundledProfile();let catalog=store.catalog()
                DispatchQueue.main.async {
                    guard let self else {return};self.profiles=catalog.profiles;self.busy=false
                    self.status="\(catalog.profiles.count) 个镜头 profile · 保存在本机应用数据中"
                    if !catalog.issues.isEmpty {self.error=catalog.issues.joined(separator:"\n")}
                    self.selected=id ?? self.selected ?? catalog.profiles.first?.id;self.readSelected()
                }
            } catch {DispatchQueue.main.async {self?.busy=false;self?.error=error.localizedDescription}}
        }
    }
    func readSelected() {
        profile=nil
        guard let id=selected else {return}
        queue.async { [weak self] in
            do {
                let p=try LCCProfileStore().load(id)
                DispatchQueue.main.async {guard self?.selected==id else {return};self?.profile=p}
            } catch {DispatchQueue.main.async {guard self?.selected==id else {return};self?.error=error.localizedDescription}}
        }
    }
    func create() {
        if let creator {creator.showWindow(nil);creator.window?.makeKeyAndOrderFront(nil);return}
        let c=LCCProfileCreatorWindowController { [weak self] summary in self?.refresh(select:summary.id) }
        c.onClose={ [weak self] in self?.creator=nil };creator=c;c.showWindow(nil);c.window?.makeKeyAndOrderFront(nil)
    }
    func reveal() {
        if let id=selected {NSWorkspace.shared.activateFileViewerSelecting([LCCProfileStore().url(for:id)])}
    }
}

struct LCCProfileLibraryView: View {
    @ObservedObject var model:LCCProfileLibraryModel
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("镜头 Profiles").font(.title.bold())
                    Text("为每种镜头与后背保存横竖方向的 LCC 标定。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("创建镜头 Profile…") {model.create()}.buttonStyle(.borderedProminent)
            }
            HSplitView {
                List(selection:$model.selected) {
                    ForEach(model.profiles) { p in
                        VStack(alignment:.leading,spacing:5) {
                            Text(p.name).font(.headline)
                            Text(p.camera).font(.caption).foregroundStyle(.secondary)
                            Text(p.variants.map {"\($0.orientation.title) \($0.count) 张"}.joined(separator:" · ")).font(.caption2)
                        }.padding(.vertical,6).tag(p.id)
                    }
                }.frame(minWidth:270,idealWidth:300,maxWidth:360)
                ScrollView {
                    if let profile=model.profile {
                        VStack(alignment:.leading,spacing:14) {
                            Text(profile.name).font(.title2.bold())
                            Text(profile.camera).foregroundStyle(.secondary)
                            if let body=LCCProfileSummary(profile).calibrationBody {Text("标定机身：\(body.name)").font(.caption)}
                            if let aperture=profile.aperture {Text("标定光圈 f/\(aperture,specifier:"%g")")}
                            Text(profile.notes).font(.callout).textSelection(.enabled)
                            ForEach(profile.orientations) { orientation in
                                let frames=profile.captures(for:orientation)
                                VStack(alignment:.leading,spacing:8) {
                                    Text("后背相对机身\(orientation.title) · \(frames.count) 张白板").font(.headline)
                                    LCCProfileCoverageView(captures:frames).frame(height:190)
                                    Text(String(format:"H %+.1f 至 %+.1f mm · V %+.1f 至 %+.1f mm",frames.map(\.shiftX).min() ?? 0,frames.map(\.shiftX).max() ?? 0,frames.map(\.shiftY).min() ?? 0,frames.map(\.shiftY).max() ?? 0))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                            }
                            Text("保留每张白板的完整低频测量，包括弱光角落。原始 RAW 不会复制到 profile，也不需要一直保留在原路径。").font(.caption).foregroundStyle(.secondary)
                            Text("拼接按后背相对机身的方向匹配标定；整机旋转会同步旋转校正场。对称机身的等价放置方向共用标定。").font(.caption).foregroundStyle(.secondary)
                        }.padding(16)
                    } else {ProgressView("读取镜头标定…").frame(maxWidth:.infinity,minHeight:280)}
                }.frame(minWidth:350)
            }
            HStack {
                if model.busy {ProgressView().controlSize(.small)}
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer();Button("在 Finder 中显示") {model.reveal()}.disabled(model.selected==nil)
            }
        }.padding(22).onAppear {model.refresh()}.onChange(of:model.selected) {_,_ in model.readSelected()}
        .alert("镜头 Profiles",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {Button("好") {model.error=nil}} message: {Text(model.error ?? "")}
    }
}

private struct LCCProfileCoverageView:View {
    let captures:[LCCProfileCapture]
    var body:some View {
        Canvas { context,size in
            guard !captures.isEmpty else {return}
            let bounds=captures.reduce(CGRect.null) {$0.union($1.fieldRect)}
            let scale=min((size.width-24)/bounds.width,(size.height-24)/bounds.height)
            let origin=CGPoint(x:(size.width-bounds.width*scale)/2,y:(size.height-bounds.height*scale)/2)
            for c in captures {
                let frame=c.fieldRect
                let r=CGRect(x:origin.x+(frame.minX-bounds.minX)*scale,
                             y:origin.y+(bounds.maxY-frame.maxY)*scale,width:frame.width*scale,height:frame.height*scale)
                context.fill(Path(r),with:.color(.cyan.opacity(0.045)))
                context.stroke(Path(r),with:.color(.cyan.opacity(0.3)),lineWidth:0.6)
                let p=CGPoint(x:r.midX,y:r.midY)
                context.fill(Path(ellipseIn:CGRect(x:p.x-2,y:p.y-2,width:4,height:4)),with:.color(.primary.opacity(0.7)))
            }
        }.background(Color(nsColor:.underPageBackgroundColor),in:RoundedRectangle(cornerRadius:6))
        .accessibilityLabel("标定照片在像场中的完整矩形覆盖范围")
    }
}
