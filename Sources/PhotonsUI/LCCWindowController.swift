import PhotonsLocalization
import AppKit
import PhotonsFileAccess
import SwiftUI
import PhotonsPanorama

@MainActor
public final class LCCWindowController: NSWindowController, NSWindowDelegate {
    private let model: LCCWindowModel
    public var onClose: (() -> Void)?
    public var onExported: (URL, @escaping (String?) -> Void) -> Void {
        get { model.onExported }
        set { model.onExported = newValue }
    }
    public init(urls: [URL], showProfiles: Bool = false) {
        model = LCCWindowModel(urls:urls)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:730),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = L10n.tr("4070f55d9a88"); window.minSize = NSSize(width:800,height:560); window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self; model.window = window
        window.contentView = NSHostingView(rootView:LCCWorkspaceView(model:model,showProfiles:showProfiles || urls.isEmpty)); window.center(); model.load()
    }
    public required init?(coder:NSCoder) { fatalError("no nib") }
    public func windowWillClose(_ notification:Notification) { model.closed = true; model.cancelCorrection(); onClose?() }
}

@MainActor
private final class LCCWindowModel: ObservableObject {
    weak var window: NSWindow?
    var closed = false
    @Published var urls: [URL]
    @Published var scenes: [PanoramaSource] = []
    @Published var flats: [LCCInspection] = []
    @Published var assignments: [Int] = []
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var selected = 0
    @Published var saved = false
    @Published var cameraBody=PanoramaCameraBody.alpa12Max
    @Published var bodyOrientation=PanoramaBodyOrientation.degrees0
    @Published var profileID = LCCLensProfile.builtInID.uuidString
    @Published var profiles:[LCCProfileSummary] = []
    @Published var shiftX = 0.0
    @Published var shiftY = 0.0
    @Published var positionConfirmed = false
    @Published var refine = true
    @Published var manifests:[Int:PanoramaManifest] = [:]
    private var resultWindow:NSWindow?
    private var exportWindow:PanoramaExportController?
    private var cancellation=PanoramaCancellation()
    func cancelCorrection() { cancellation.cancel() }
    var onExported: (URL, @escaping (String?) -> Void) -> Void = { _, done in done(nil) }

    private var sourceAccess: [FileAccess] = []
    private let queue = DispatchQueue(label:"Photons.lcc",qos:.userInitiated)
    init(urls:[URL]) {
        sourceAccess = urls.map { FileAccessStore.shared.access(to: $0) }
        self.urls = sourceAccess.map(\.url)
    }
    func load() {
        busy = true; status = L10n.tr("5ce551a5f536")
        let urls = self.urls
        queue.async { [weak self] in
            do {
                let scenes = try urls.map { try PanoramaSource(url:$0) }
                var manifests:[Int:PanoramaManifest]=[:]
                for (i,url) in urls.enumerated() {if let manifest=try PanoramaManifest.read(from:url) {manifests[i]=manifest}}
                let store=LCCProfileStore();try store.installBundledProfile()
                let profiles=store.catalog().profiles
                let records = LCCPairingStore().records().filter { urls.contains($0.scene) }
                let flatURLs = Array(Set(records.map(\.flat))).sorted { $0.lastPathComponent < $1.lastPathComponent }
                let flatAccess = flatURLs.map { FileAccessStore.shared.access(to: $0) }
                let flats = try flatAccess.map { try LCCInspector.inspect($0.url) }
                let assignments = urls.map { u in records.first(where: { $0.scene == u }).flatMap { r in flatURLs.firstIndex(of:r.flat) } ?? -1 }
                DispatchQueue.main.async {
                    guard let self, !self.closed else { return }
                    self.sourceAccess += flatAccess
                    self.manifests=manifests;self.profiles=profiles
                    self.scenes = scenes; self.flats = flats; self.assignments = assignments; self.busy = false
                    self.saved = !scenes.isEmpty && assignments.allSatisfy { $0 >= 0 }
                    self.status = self.saved ? L10n.tr("cd392f12e4da") : L10n.tr("f3a2a43f5215")
                }
            } catch { DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription } }
        }
    }
    func choose(scenes:Bool) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = scenes ? L10n.tr("a73473ed6b17") : L10n.tr("0f70ac46e5a3")
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            do { for url in urls { try FileAccessStore.shared.rememberSelection(url) } }
            catch { self.error = error.localizedDescription; return }
            self.sourceAccess += urls.map { FileAccessStore.shared.access(to: $0) }
            if scenes { self.urls = urls; self.saved = false; self.load() }
            else { self.addFlats(urls) }
        }
    }
    private func addFlats(_ urls:[URL]) {
        busy = true; status = L10n.tr("1a0105d45d33")
        let existing = Set(flats.map { $0.source.url })
        queue.async { [weak self] in
            do {
                let fresh = try urls.filter { !existing.contains($0) }.map { try LCCInspector.inspect($0) }
                DispatchQueue.main.async {
                    guard let self, !self.closed else { return }
                    self.flats += fresh; self.busy = false; self.saved = false
                    self.status = L10n.tr("dd01a5cc3a83")
                }
            } catch { DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription } }
        }
    }
    func pairInOrder(reverse:Bool) {
        guard scenes.count == flats.count else { return }
        let order = flats.indices.sorted { flats[$0].source.url.lastPathComponent.localizedStandardCompare(flats[$1].source.url.lastPathComponent) == .orderedAscending }
        let sourceOrder = scenes.indices.sorted { scenes[$0].url.lastPathComponent.localizedStandardCompare(scenes[$1].url.lastPathComponent) == .orderedAscending }
        let target = reverse ? Array(order.reversed()) : order
        for (s,f) in zip(sourceOrder,target) { assignments[s] = f }
        saved = false; status = L10n.tr("bffb62fbd550")
    }
    func issue(_ index:Int) -> String? {
        guard assignments.indices.contains(index), assignments[index]>=0, flats.indices.contains(assignments[index]) else { return L10n.tr("e7eb72afa632") }
        let f = assignments[index]
        if assignments.filter({ $0 == f }).count > 1 { return L10n.tr("caafba41957c") }
        return LCCInspector.incompatibility(scene:scenes[index],flat:flats[f].source)
    }
    var canSave: Bool { !busy && !scenes.isEmpty && scenes.indices.allSatisfy { issue($0) == nil } }
    func correct(traditional:Bool) {
        guard !busy,scenes.indices.contains(selected) else {return}
        if traditional {guard canSave else {return};save()}
        let index=selected,source=scenes[index],manifest=manifests[index]
        if !traditional && manifest?.profileOffsetMM == nil && !positionConfirmed {
            error=L10n.tr("fca64867d785");return
        }
        let flat=traditional ? flats[assignments[index]].source.url:nil
        let id=UUID(uuidString:profileID),position=CGPoint(x:shiftX,y:shiftY),refine=self.refine
        let suppliedPosition=positionConfirmed,body=cameraBody,orientation=bodyOrientation
        busy=true;error=nil;status=L10n.tr("c7bbd14f9634");cancellation=PanoramaCancellation()
        let token=cancellation
        queue.async { [weak self] in
            do {
                let progress:PanoramaEngine.Progress={message in DispatchQueue.main.async {self?.status=message}}
                let plan:PanoramaPlan,provenance:PanoramaManifest
                if let flat {
                    plan=try LCCCorrectionEngine.traditional(scene:source,flatURL:flat,cancellation:token,progress:progress)
                    var data=PanoramaManifest(plan:plan);data.correctionMethod="strict-flat-field";provenance=data
                } else {
                    guard let id else {throw PanoramaFailure(L10n.tr("18758dce1d62"))}
                    let profile=try LCCProfileStore().load(id)
                    if let manifest {
                        let result=try LCCCorrectionEngine.postProcess(scene:source,manifest:manifest,profile:profile,
                            offset:suppliedPosition ? CGPoint(x:-position.x,y:-position.y):nil,cancellation:token,progress:progress)
                        plan=result.plan;provenance=result.manifest
                    } else {
                        let result=try LCCCorrectionEngine.single(scene:source,profile:profile,position:position,refine:refine,body:body,orientation:orientation,cancellation:token,progress:progress)
                        plan=result.plan;provenance=PanoramaManifest(plan:plan)
                        DispatchQueue.main.async {self?.shiftX=result.position.x;self?.shiftY=result.position.y}
                    }
                }
                DispatchQueue.main.async {
                    guard let self,!self.closed else {return}
                    self.busy=false;self.status=L10n.tr("f31f21c22b68")
                    self.showResult(plan,manifest:provenance)
                }
            } catch {DispatchQueue.main.async {self?.busy=false;self?.error=error.localizedDescription}}
        }
    }
    private func showResult(_ plan:PanoramaPlan,manifest:PanoramaManifest) {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title=L10n.tr("a68e350ac627");window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:LCCResultView(plan:plan,post:manifest.correctionMethod=="rendered-rgb-post-correction") { [weak self,weak window] in
            guard let self,let window else {return}
            let controller=PanoramaExportController(plan:plan,manifest:manifest)
            controller.model.preset.nameTemplate=sourceNameForLCC(plan)
            controller.onExported=self.onExported
            controller.onQueued={ [weak window] in window?.close() }
            self.exportWindow=controller;controller.present(in:window)
        })
        resultWindow=window;window.center();window.makeKeyAndOrderFront(nil)
    }
    func save() {
        guard canSave else { return }
        do {
            let pairs = try scenes.indices.map { try LCCPairRecord(scene:scenes[$0].url,flat:flats[assignments[$0]].source.url,confirmed:true) }
            try LCCPairingStore().save(pairs); saved = true; status = L10n.tr("412e76858234")
        } catch { self.error = error.localizedDescription }
    }
}

private struct LCCPairingView: View {
    @ObservedObject var model:LCCWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text(L10n.tr("6abae60810ba")).font(.title.bold())
                    Text(L10n.tr("6d38f48f99b2")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("71a78a42af7e")) { model.choose(scenes:true) }
                Button(L10n.tr("46dd6450d88b")) { model.choose(scenes:false) }.buttonStyle(.borderedProminent)
            }
            HStack {
                Text(L10n.tr("1240efcb239a" , String(describing: (model.scenes.count)), String(describing: (model.flats.count)))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("55a7bf2a5c93")) { model.pairInOrder(reverse:false) }.disabled(model.scenes.isEmpty || model.scenes.count != model.flats.count)
                Button(L10n.tr("62f4f9bd810b")) { model.pairInOrder(reverse:true) }.disabled(model.scenes.isEmpty || model.scenes.count != model.flats.count)
            }
            HSplitView {
                ScrollView {
                    VStack(spacing:8) {
                        if model.scenes.isEmpty { Text(L10n.tr("980c8f04383a")).foregroundStyle(.secondary).padding(30) }
                        ForEach(model.scenes.indices,id:\.self) { i in
                            VStack(alignment:.leading,spacing:8) {
                                HStack { Text(model.scenes[i].url.lastPathComponent).font(.headline); Spacer(); if model.saved { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) } }
                                Picker(L10n.tr("727e74b0c370"),selection:Binding(get:{ model.assignments[i] },set:{ model.assignments[i] = $0; model.selected = i; model.saved = false })) {
                                    Text(L10n.tr("da590a8fe3ce")).tag(-1)
                                    ForEach(model.flats.indices,id:\.self) { f in Text(model.flats[f].source.url.lastPathComponent).tag(f) }
                                }
                                if let issue = model.issue(i) { Text(issue).font(.caption).foregroundStyle(.orange) }
                                else { Text(L10n.tr("da7aa9bc8f48")).font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).background(i == model.selected ? Color.accentColor.opacity(0.1):Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                                .onTapGesture { model.selected = i }
                        }
                    }.padding(4)
                }.frame(minWidth:360)
                VStack(alignment:.leading,spacing:12) {
                    if model.assignments.indices.contains(model.selected), model.flats.indices.contains(model.assignments[model.selected]) {
                        let flat = model.flats[model.assignments[model.selected]]
                        Text(flat.source.url.lastPathComponent).font(.headline)
                        if let cg = flat.thumbnail { Image(decorative:cg,scale:1).resizable().aspectRatio(contentMode:.fit) }
                        Text(flat.source.camera).font(.caption)
                        Text("\(Int(flat.source.size.width)) × \(Int(flat.source.size.height))").font(.caption).foregroundStyle(.secondary)
                        Text(flat.message).font(.callout).foregroundStyle(flat.likelyFlat ? Color.secondary:Color.orange)
                    } else { Text(L10n.tr("0d3a4952e5a8")).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
                    Spacer()
                    Text(L10n.tr("03bcfaea2fab")).font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(minWidth:280)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("3077d89627b1")) { model.correct(traditional:true) }.disabled(!model.canSave)
                Button(L10n.tr("8234d1bf247e")) { model.save() }.buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }.padding(24).disabled(model.busy)
            .alert(L10n.tr("29d1945ab067"),isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) { Button(L10n.tr("f867f3417859")) { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

private struct LCCWorkspaceView: View {
    @ObservedObject var model:LCCWindowModel
    @State private var selection:Int
    @StateObject private var libraryModel=LCCProfileLibraryModel()
    init(model:LCCWindowModel,showProfiles:Bool) {self.model=model;_selection=State(initialValue:showProfiles ? 2:0)}
    var body:some View {
        VStack(spacing:0) {
            Picker(L10n.tr("2028834f2b6b"),selection:$selection) {
                Text(L10n.tr("17b409bc4ecb")).tag(0);Text(L10n.tr("36be15abd92b")).tag(1);Text(L10n.tr("bba6488b8640")).tag(2)
            }.pickerStyle(.segmented).frame(width:510).padding(.top,16)
            if selection==0 {LCCPairingView(model:model)} else if selection==1 {LCCProfileCorrectionView(model:model)} else {LCCProfileLibraryView(model:libraryModel)}
        }
    }
}

private func sourceNameForLCC(_ plan:PanoramaPlan)->String {
    (plan.sources.first?.url.deletingPathExtension().lastPathComponent ?? "Photo")+"_lcc"
}
private struct LCCResultView:View {
    let plan:PanoramaPlan
    let post:Bool
    let export:()->Void
    var body:some View {
        VStack {
            if let image=plan.preview {PanoramaHDRPreview(image:image).frame(maxWidth:.infinity,maxHeight:.infinity)}
            HStack {
                Text(post ? L10n.tr("7b9fc5d84c0d"):L10n.tr("d098a748d520"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer();Button(L10n.tr("1405051c6675"),action:export).buttonStyle(.borderedProminent)
            }.padding()
        }
    }
}
private struct LCCProfileCorrectionView:View {
    @ObservedObject var model:LCCWindowModel
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text(L10n.tr("36be15abd92b")).font(.title.bold());Spacer();Button(L10n.tr("ac8ccd7914cd")) {model.choose(scenes:true)}}
            Picker(L10n.tr("7b50017ae47e"),selection:$model.selected) {ForEach(model.scenes.indices,id:\.self) {Text(model.scenes[$0].url.lastPathComponent).tag($0)}}
            Picker(L10n.tr("5c30b533510f"),selection:$model.profileID) {ForEach(model.profiles) {Text($0.name).tag($0.id.uuidString)}}
            if let manifest=model.manifests[model.selected] {
                Text(L10n.tr("6255d52c9bfe" , String(describing: (manifest.frames.count)), String(describing: (manifest.profileName ?? L10n.tr("854f821696ae"))))).font(.headline)
                Text(manifest.correctionApplied ? L10n.tr("14f6c2f69469"):L10n.tr("40c001b76410"))
                    .foregroundStyle(.secondary)
            } else {Text(L10n.tr("15b15c887158")).foregroundStyle(.secondary)}
            if model.manifests[model.selected] == nil {
                Picker(L10n.tr("ee38b80c37d9"),selection:$model.cameraBody) {ForEach(PanoramaCameraBody.allCases) {Text($0.name).tag($0)}}
                PanoramaBodyOrientationPicker(cameraBody:model.cameraBody,selection:$model.bodyOrientation)
            } else {
                Text(L10n.tr("64f1d2691e0c")).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L10n.tr("6ddef7f6075c"),isOn:$model.positionConfirmed)
            HStack {TextField(L10n.tr("4995b90d72fc"),value:$model.shiftX,format:.number);TextField(L10n.tr("1777a1e5f3a5"),value:$model.shiftY,format:.number)}.disabled(!model.positionConfirmed)
            Toggle(L10n.tr("3d0cb62afa54"),isOn:$model.refine).disabled(model.manifests[model.selected] != nil)
            Text(L10n.tr("7a9cfbc9eceb")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {if model.busy {ProgressView().controlSize(.small)};Text(model.status).foregroundStyle(.secondary);Spacer()
                Button(L10n.tr("19e40f9ff2dc")) {model.correct(traditional:false)}.buttonStyle(.borderedProminent)
                    .disabled(model.scenes.isEmpty || model.manifests[model.selected]?.correctionApplied == true)
            }
        }.padding(24).disabled(model.busy)
        .onChange(of:model.selected) {_,_ in model.positionConfirmed=false}
        .alert(L10n.tr("91a5d44e3599"),isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {Button(L10n.tr("f867f3417859")) {model.error=nil}} message:{Text(model.error ?? "")}
    }
}
