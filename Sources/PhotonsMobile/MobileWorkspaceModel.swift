#if os(iOS)
import PhotonsLocalization
import SwiftUI
import PhotonsLocalization
import UIKit
import PhotonsCore
import PhotonsCatalog
import PhotonsPanorama

@MainActor
final class MobileWorkspaceModel: ObservableObject {
    @Published var photos: [MobilePhoto] = []
    @Published var folders = MobileFolderIndex()
    @Published var folderScope = MobileFolderScope.all
    var folderPhotos: [MobilePhoto] { photos.filter { folders.contains($0.id,in: folderScope) } }
    func chooseFolder(_ scope: MobileFolderScope) { guard !busy else { return }; clearSelection(); folderScope = scope; showGrid = true }
    func moveSelection(to folder: UUID?) {
        let ids = selected
        run(L10n.tr("ipad.8d3225a3f8c7")) {
            try await self.engine.movePhotos(ids,to: folder); try await self.reload(); self.clearSelection()
        }
    }
    func removeFolder(_ id: UUID) {
        run(L10n.tr("ipad.c828063bffb6")) {
            try await self.engine.removeFolder(id)
            if self.folderScope == .folder(id) { self.folderScope = .unfiled }
            try await self.reload(); self.clearSelection()
        }
    }
    @Published var selected: Set<String> = []
    @Published var active: MobilePhoto?
    @Published var edit = EditModel.neutral
    @Published var history = EditHistory()
    @Published var frame: MobileFrame?
    @Published var detailFrame: MobileDetailFrame?
    @Published var detailStatus = ""
    @Published var thumbnails: [String: MobileFrame] = [:]
    @Published var previewErrors: [String: String] = [:]
    @Published var plan: PanoramaPlan?
    @Published var manifest: PanoramaManifest?
    @Published var lccPositionNote: String?
    @Published var profiles: [LCCProfileSummary] = []
    @Published var busy = false
    @Published var rendering = false
    @Published var selectionLoading = false
    @Published var status = ""
    @Published var progress: Double?
    @Published var error: String?
    @Published var output: URL?
    @Published var showGrid = true
    @Published var hdr = UserDefaults.standard.object(forKey: "photons.mobile.hdr") as? Bool ?? true
    let engine: MobileEngine
    init(engine: MobileEngine? = nil) {
        if let engine { self.engine = engine; return }
        // Generated UI-test examples stay separate from the user's working library.
        let sampleLibrary = ProcessInfo.processInfo.arguments.contains("--demo")
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Generated Samples.photonslibrary") : nil
        if let sampleLibrary, ProcessInfo.processInfo.arguments.contains("--reset-demo") {
            try? FileManager.default.removeItem(at: sampleLibrary)
        }
        self.engine = MobileEngine(libraryURL: sampleLibrary)
    }
    private var job: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailRevision = 0
    private var visibleThumbnailIDs: Set<String> = []
    private var panoramaThumbnailIDs: Set<String> = []
    private var staleThumbnailIDs: Set<String> = []
    private var thumbnailOrder: [String] = []
    private var started = false
    private var selectionTask: Task<Void, Never>?
    private var cancellation = PanoramaCancellation()
    private var generation = 0
    private var selectionRevision = 0
    private var detailTask: Task<Void,Never>?
    private var detailRevision = 0
    private var viewport: MobileDetailRequest?
    var canvasSize: CGSize? {
        if let plan { return plan.outputSize }
        if let size = frame?.fullSize { return CGSize(width: size.width,height: size.height) }
        guard let photo = active, photo.width > 0, photo.height > 0 else { return nil }
        let size = CropGeometry(geometry: edit.geometry,source: ImageSize(width: photo.width,height: photo.height)).canvas
        return CGSize(width: size.width,height: size.height)
    }
    private func invalidateDetail(clearViewport: Bool = false) {
        detailTask?.cancel(); detailRevision += 1; detailFrame = nil; detailStatus = ""
        if clearViewport { viewport = nil }
    }
    func requestDetail(_ request: MobileDetailRequest?) {
        viewport = request
        detailTask?.cancel(); detailRevision += 1
        // The panorama workspace displays the analysis preview. Zooming must not start
        // a full source decode/composite; full-quality rendering belongs to export.
        if plan != nil {
            detailFrame = nil
            detailStatus = request == nil ? "" : L10n.tr("panorama.preview.lowResolution")
            return
        }
        guard let request, !selectionLoading, !busy, let photo = active else { detailFrame = nil; detailStatus = ""; return }
        let ticket = detailRevision, values = edit, mode = hdr
        detailTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                detailStatus = L10n.tr("ipad.02b3d04c1ad2")
                let result = try await engine.detail(photo,edit: values,hdr: mode,request: request)
                guard !Task.isCancelled, ticket == detailRevision else { return }
                detailFrame = result
                detailStatus = result.resolutionScale + 0.001 < min(1,request.scale)
                    ? L10n.tr("ipad.zoom.detailLimited",String(format: "%.0f",result.resolutionScale * 100)) : ""
            } catch is CancellationError { }
            catch { if ticket == detailRevision { detailStatus = error.localizedDescription } }
        }
    }
    private var panoramaReturnToGrid: Bool?
    private var panoramaExporting = false

    func beginPanorama() {
        panoramaReturnToGrid = showGrid
        panoramaThumbnailIDs = visibleThumbnailIDs
        stopThumbnailLoading()
    }
    /// A stitch is a temporary workspace, not a photograph in the library.
    /// Export captures its plan before dismissal; only the saved output enters the library.
    func endPanorama() {
        guard let returnToGrid = panoramaReturnToGrid else { return }
        panoramaReturnToGrid = nil
        visibleThumbnailIDs.formUnion(panoramaThumbnailIDs)
        panoramaThumbnailIDs.removeAll()
        invalidateDetail(clearViewport: true)
        if busy && !panoramaExporting { cancel() }
        previewTask?.cancel(); generation += 1; rendering = false
        plan = nil; manifest = nil; lccPositionNote = nil
        frame = active.flatMap { thumbnails[$0.id] }
        showGrid = returnToGrid
        if !returnToGrid { render() }
        warmThumbnails()
    }

    var selectedPhotos: [MobilePhoto] { photos.filter { selected.contains($0.id) } }
    var canExport: Bool { plan != nil || active != nil }
    func start() async {
        // SwiftUI can restart the root .task after dismissing a full-screen workspace.
        guard !started else { warmThumbnails(); return }
        started = true
        do {
            try await reload()
            if ProcessInfo.processInfo.arguments.contains("--boston"), !MobileSamples.boston.isEmpty {
                importPhotos(MobileSamples.boston)
            } else if ProcessInfo.processInfo.arguments.contains("--demo"), photos.isEmpty {
                let urls = try await Task.detached { try MobileSamples.create() }.value
                importPhotos(urls)
            } else { warmThumbnails() }
        } catch { started = false; self.error = error.localizedDescription }
    }
    func reload() async throws {
        photos = try await engine.photos(); profiles = try await engine.profiles(); folders = try await engine.folderIndex()
    }
    func thumbnailVisibility(_ id: String, visible: Bool) {
        if visible {
            visibleThumbnailIDs.insert(id)
            warmThumbnails()
        } else { visibleThumbnailIDs.remove(id) }
    }
    private var protectedThumbnailIDs: Set<String> {
        visibleThumbnailIDs.union(panoramaThumbnailIDs).union(active.map { [$0.id] } ?? [])
    }
    private func stopThumbnailLoading() {
        thumbnailTask?.cancel(); thumbnailTask = nil; thumbnailRevision += 1
    }
    private func trimThumbnails(underPressure: Bool = false) {
        let keep = protectedThumbnailIDs
        if underPressure { thumbnails = thumbnails.filter { keep.contains($0.key) } }
        // Keep a small recent scroll-back cache, plus the cells actually on screen.
        while thumbnails.count > max(64,keep.count) {
            guard let id = thumbnailOrder.first(where: { thumbnails[$0] != nil && !keep.contains($0) })
                ?? thumbnails.keys.sorted().first(where: { !keep.contains($0) }) else { break }
            thumbnails.removeValue(forKey: id)
        }
        thumbnailOrder.removeAll { thumbnails[$0] == nil }
        staleThumbnailIDs.formIntersection(thumbnails.keys)
    }
    func warmThumbnails(refreshExisting: Bool = false) {
        if refreshExisting {
            staleThumbnailIDs.formUnion(thumbnails.keys)
            stopThumbnailLoading()
        }
        guard !busy, panoramaReturnToGrid == nil, showGrid, thumbnailTask == nil else { return }
        thumbnailRevision += 1
        let ticket = thumbnailRevision
        thumbnailTask = Task {
            defer { if ticket == thumbnailRevision { thumbnailTask = nil } }
            // Coalesce the grid's cell appearances without restarting an in-flight decode.
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            var failed: Set<String> = []
            while !Task.isCancelled && !busy && panoramaReturnToGrid == nil && showGrid {
                let needed = visibleThumbnailIDs.isEmpty
                    ? Set(folderPhotos.prefix(12).map(\.id)) : visibleThumbnailIDs
                guard let photo = photos.first(where: {
                    needed.contains($0.id) && !failed.contains($0.id)
                        && (thumbnails[$0.id] == nil || staleThumbnailIDs.contains($0.id))
                }) else { break }
                let mode = hdr
                do {
                    let value = try await engine.thumbnail(photo,hdr: mode)
                    guard !Task.isCancelled, mode == hdr else { break }
                    thumbnails[photo.id] = value; staleThumbnailIDs.remove(photo.id)
                    thumbnailOrder.removeAll { $0 == photo.id }; thumbnailOrder.append(photo.id)
                    previewErrors.removeValue(forKey: photo.id)
                    if active?.id == photo.id && showGrid && plan == nil { frame = value }
                    trimThumbnails()
                } catch is CancellationError { break }
                catch { failed.insert(photo.id); previewErrors[photo.id] = error.localizedDescription }
                await Task.yield()
            }
        }
    }
    func select(_ photo: MobilePhoto, open: Bool = false) {
        invalidateDetail(clearViewport: true)
        previewTask?.cancel(); selectionTask?.cancel(); generation += 1
        selectionRevision += 1
        let ticket = selectionRevision
        selectionLoading = true; rendering = false
        edit = .neutral; history = EditHistory()
        active = photo; frame = thumbnails[photo.id]; plan = nil; manifest = nil; lccPositionNote = nil
        if open { selected = [photo.id]; showGrid = false }
        selectionTask = Task {
            do {
                let values = try await engine.edit(photo.id)
                let stack = try await engine.history(photo.id)
                guard !Task.isCancelled, ticket == selectionRevision else { return }
                selectionLoading = false
                edit = values; history = stack
                if !showGrid { render() }
            } catch { if !Task.isCancelled { selectionLoading = false; self.error = error.localizedDescription } }
        }
    }
    func toggleSelection(_ photo: MobilePhoto) {
        // A checkbox changes the selection set, not the active editor or its render jobs.
        if selected.contains(photo.id) { selected.remove(photo.id) } else { selected.insert(photo.id) }
    }
    func clearSelection() {
        invalidateDetail(clearViewport: true)
        previewTask?.cancel(); selectionTask?.cancel()
        generation += 1; selectionRevision += 1
        selected.removeAll(); active = nil; frame = nil; plan = nil; manifest = nil
        selectionLoading = false; rendering = false
    }
    func movePhoto(by offset: Int, among visible: [MobilePhoto]) {
        guard !busy, plan == nil, let id = active?.id,
              let index = visible.firstIndex(where: { $0.id == id }),
              visible.indices.contains(index + offset) else { return }
        select(visible[index + offset], open: true)
    }
    func render() {
        guard !busy, !selectionLoading, let photo = active, plan == nil else { return }
        invalidateDetail()
        previewTask?.cancel(); generation += 1
        let ticket = generation, values = edit, hdr = hdr
        rendering = true
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await engine.frame(photo, edit: values, hdr: hdr)
                guard !Task.isCancelled, ticket == generation else { return }
                frame = result; rendering = false
                requestDetail(viewport)
            } catch is CancellationError { }
            catch { if ticket == generation { rendering = false; self.error = error.localizedDescription } }
        }
    }
    func update(_ path: WritableKeyPath<EditModel, Double>, _ value: Double) { edit[keyPath: path] = value; render() }
    func mutate(_ label: String, _ mutation: (inout EditModel) -> Void) { mutation(&edit); commit(label); render() }
    func commit(_ label: String) {
        guard !selectionLoading, let photo = active else { return }
        history.commit(edit, label: label, coalesce: false)
        let values = edit, stack = history
        Task {
            do {
                try await engine.save(values, history: stack, id: photo.id)
                let thumb = try await engine.thumbnail(photo, hdr: hdr)
                thumbnails[photo.id] = thumb
            } catch { self.error = error.localizedDescription }
        }
    }
    func undo() { if let value = history.undo() { restore(value) } }
    func redo() { if let value = history.redo() { restore(value) } }
    func jump(_ seq: Int) { if let value = history.jump(to: seq) { restore(value) } }
    private func restore(_ value: EditModel) {
        edit = value; render()
        guard let id = active?.id else { return }
        let stack = history
        Task {
            do {
                try await engine.save(value, history: stack, id: id)
                if let photo = photos.first(where: { $0.id == id }) { thumbnails[id] = try await engine.thumbnail(photo, hdr: hdr) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func reset() {
        guard let id = active?.id else { return }
        Task {
            do { let original = try await engine.importedEdit(id); mutate(L10n.tr("ipad.53fc2db3b345")) { $0 = original } }
            catch { self.error = error.localizedDescription }
        }
    }
    func toggleHDR() {
        hdr.toggle(); UserDefaults.standard.set(hdr, forKey: "photons.mobile.hdr")
        if let plan {
            // A display-mode switch does not change panorama tone or recomposite sources.
            // Let an in-flight tone update finish with the current display mode.
            if !rendering {
                invalidateDetail(); generation += 1
                let ticket = generation, mode = hdr
                previewTask = Task {
                    do {
                        let result = try await engine.frame(plan,hdr: mode)
                        guard !Task.isCancelled, ticket == generation else { return }
                        frame = result; requestDetail(viewport)
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
            }
        } else { render() }
        warmThumbnails(refreshExisting: true)
    }
    func setRating(_ rating: Int) {
        guard let photo = active else { return }
        Task {
            do { try await engine.rating(rating, id: photo.id); try await reload() }
            catch { self.error = error.localizedDescription }
        }
    }
    private var report: @Sendable (String, Double?) -> Void {
        { [weak self] text,fraction in Task { @MainActor in self?.status = text; self?.progress = fraction } }
    }
    private func run(_ title: String, work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        invalidateDetail()
        stopThumbnailLoading(); previewTask?.cancel(); generation += 1; rendering = false
        busy = true; status = title; progress = nil; cancellation = PanoramaCancellation()
        job = Task {
            do { try await work() }
            catch is CancellationError { status = L10n.tr("a37778f17c5f") }
            catch { self.error = error.localizedDescription }
            busy = false; progress = nil
            status = ""; requestDetail(viewport)
            warmThumbnails()
        }
    }
    func cancel() { cancellation.cancel(); job?.cancel(); status = L10n.tr("e8e08b0f61dd") }
    func importPhotos(_ urls: [URL]) {
        let destination: UUID?
        if case .folder(let id) = folderScope { destination = id } else { destination = nil }
        run(L10n.tr("ipad.d252fffacbf0")) {
            let summary = try await self.engine.importPhotos(urls, skipDuplicates: UserDefaults.standard.object(forKey: "photons.mobile.skipDuplicates") as? Bool ?? true, folder: destination,progress: self.report)
            try await self.reload()
            if summary.failed > 0 { self.error = L10n.tr("ipad.c4d002431eed", String(describing: (summary.failed))) }
            self.warmThumbnails()
        }
    }
    func importProfile(_ url: URL) {
        run(L10n.tr("ipad.fd4d52fa1e2c")) { try await self.engine.importProfile(url); self.profiles = try await self.engine.profiles() }
    }
    func stitch(options: PanoramaOptions, positions: [Int: CGPoint], shiftHints: [Int: PanoramaShiftPosition] = [:], sensor: SensorSize?,
                registrationMode: PanoramaRegistrationMode, onAligned: @escaping (PanoramaPlan) -> Void) {
        let sources = selectedPhotos, tone = plan?.tone ?? .panoramaDefault
        run(L10n.tr("ipad.29baca75d5da")) {
            let result = try await self.engine.analyze(sources, options: options, positions: positions, shiftHints: shiftHints, sensor: sensor, registrationMode: registrationMode,
                                                       tone: tone,cancellation: self.cancellation, progress: self.report)
            let frame = try await self.engine.frame(result, hdr: self.hdr)
            try Task.checkCancellation()
            self.plan = result; self.manifest = nil; self.lccPositionNote = nil; self.frame = frame; self.showGrid = false
            onAligned(result)
        }
    }
    func setPanoramaTone(_ tone: PanoramaToneSettings) {
        guard !busy, tone.isValid, var plan else { return }
        invalidateDetail()
        // Publish the output parameters immediately. A pending preview can be cancelled safely;
        // export and a subsequent LCC/alignment job still see the latest requested settings.
        plan.tone = tone; self.plan = plan; manifest?.tone = tone
        previewTask?.cancel(); generation += 1; rendering = true
        let ticket = generation
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(100))
                let updated = try await engine.adjustPanoramaTone(plan,settings: tone)
                let rendered = try await engine.frame(updated,hdr: self.hdr)
                guard !Task.isCancelled,ticket == generation else { return }
                self.plan = updated; frame = rendered; rendering = false
                requestDetail(viewport)
            } catch is CancellationError { }
            catch { if ticket == generation { rendering = false; self.error = error.localizedDescription } }
        }
    }
    func correct(flat: URL?, profileID: UUID?, position: CGPoint?, refine: Bool,
                 body: PanoramaCameraBody, orientation: PanoramaBodyOrientation) {
        guard let photo = active else { return }
        run(L10n.tr("ipad.40c527f3f714")) {
            let result = try await self.engine.correct(photo, flat: flat, profileID: profileID, position: position, refine: refine,
                body: body, orientation: orientation, cancellation: self.cancellation, progress: self.report)
            self.plan = result.0; self.manifest = result.1; self.frame = try await self.engine.frame(result.0, hdr: self.hdr); self.showGrid = false
        }
    }
    func updatePanoramaOptions(_ options: PanoramaOptions) {
        guard !busy, let original = plan, original.isRegistered else { return }
        let previous = manifest
        run(L10n.tr("b087e27f78f6")) {
            let updated = try await self.engine.updatePanorama(original, options: options, cancellation: self.cancellation)
            let frame = try await self.engine.frame(updated, hdr: self.hdr)
            try self.cancellation.check()
            self.plan = updated; self.frame = frame
            self.manifest = PanoramaManifest(plan: updated, profileID: previous?.profileID, profileName: previous?.profileName,
                offsetMM: previous?.profileOffsetMM, sensor: previous?.frames.first?.sensor,
                bodyOrientation: previous?.bodyOrientation ?? .degrees0, cameraBody: previous?.cameraBody)
        }
    }
    func correctPanorama(profileID: UUID, offset: CGPoint?, body: PanoramaCameraBody, orientation: PanoramaBodyOrientation,
                         shiftHints: [Int: PanoramaShiftPosition] = [:], sensor: SensorSize? = nil, cropToCoverage: Bool = false) {
        guard let plan else { return }
        run(L10n.tr("ipad.9d9a557acc3c")) {
            let updated = try await self.engine.correctPanorama(plan, profileID: profileID, offset: offset, body: body,
                orientation: orientation, shiftHints: shiftHints, sensor: sensor, cropToCoverage: cropToCoverage, cancellation: self.cancellation, progress: self.report)
            let frame = try await self.engine.frame(updated, hdr: self.hdr)
            try Task.checkCancellation()
            self.plan = updated
            self.manifest = nil
            self.lccPositionNote = offset == nil ? L10n.tr("ipad.ff75b3b3ea64") : nil
            self.frame = frame
        }
    }
    func setLCCCrop(_ enabled: Bool) {
        guard let plan else { return }
        run(L10n.tr("ipad.b2890667bbfb")) {
            let updated = try await self.engine.setLCCCrop(plan, enabled: enabled, cancellation: self.cancellation)
            let frame = try await self.engine.frame(updated, hdr: self.hdr)
            try Task.checkCancellation()
            self.plan = updated; self.manifest = nil
            self.frame = frame
        }
    }
    func createProfile(name: String, frames: [LCCCreationFrame], sensor: SensorSize) {
        run(L10n.tr("ipad.5f845b591681")) {
            try await self.engine.createProfile(name: name, frames: frames, sensor: sensor, cancellation: self.cancellation, progress: self.report)
            self.profiles = try await self.engine.profiles()
        }
    }
    func export(_ settings: MobileExportSettings) {
        guard !busy else { return }
        let photo = active, edit = edit, plan = plan, manifest = manifest
        panoramaExporting = panoramaReturnToGrid != nil
        run(L10n.tr("ipad.eb9b51193618")) {
            defer { self.panoramaExporting = false }
            self.output = try await self.engine.export(photo: photo, edit: edit, plan: plan, manifest: manifest,
                settings: settings, cancellation: self.cancellation, progress: self.report)
            try await self.reload(); self.warmThumbnails()
        }
    }
    func memoryWarning() {
        invalidateDetail(clearViewport: true)
        previewTask?.cancel(); generation += 1; rendering = false
        stopThumbnailLoading(); trimThumbnails(underPressure: true)
        Task {
            await engine.releaseWorkingMemory()
            warmThumbnails()
        }
    }
    func clearPreviewCache() async throws {
        guard !busy else { throw MobileError.message(L10n.tr("ipad.580e1a655542")) }
        busy = true
        defer { busy = false; warmThumbnails() }
        previewTask?.cancel(); stopThumbnailLoading()
        generation += 1; rendering = false
        invalidateDetail(); status = ""; progress = nil
        // Finish loading the selected photo's saved edits; cancelling this load could leave
        // neutral controls attached to an edited photograph when settings are dismissed.
        await selectionTask?.value
        try await engine.clearPreviewCache()
        // Keep the image currently on screen; subsequent requests regenerate disposable previews.
    }
}
#endif
