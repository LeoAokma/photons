#if os(iOS)
import Foundation
import CoreImage
import ImageIO
import CryptoKit
import PhotonsCore
import PhotonsCatalog
import PhotonsPanorama
import PhotonsExport
import PhotonsJobs
import PhotonsFileAccess

struct MobilePhoto: Identifiable, Sendable {
    var id: String
    var name: String
    var url: URL
    var rating: Int
    var width: Int
    var height: Int
}
struct MobileFrame: @unchecked Sendable {
    var image: CGImage
    var histogram: Histogram?
}
struct MobileExportSettings: Sendable {
    var format = "heic"
    var hdr = true
    var longEdge = 4096
    var quality = 0.92
    var preset: ExportPreset {
        let f = ExportFormat(rawValue: format) ?? .heic
        return ExportPreset(format: f, longEdge: longEdge > 0 ? longEdge : nil,
                            quality: quality, bitDepth: f == .tiff || f == .png ? 16 : 8,
                            hdrKind: hdr ? f.defaultHDRKind : .none,
                            watermarkText: "")
    }
}

/// All expensive work and mutable GPU objects are confined to one actor. The platform UI never
/// implements image arithmetic. This is an in-process executor, not macOS helper-process isolation.
actor MobileEngine {
    let libraryURL: URL
    private var catalog: Catalog?
    private var graph: RenderGraph?
    private var sourceSizes: [URL: ImageSize] = [:]
    private var graphKey = ""
    private var graphSize = ImageSize(width: 1, height: 1)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cachedFrames: [String: MobileFrame] = [:]
    private var cacheOrder: [String] = []

    init(libraryURL: URL? = nil) {
        self.libraryURL = libraryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPad Preview.photonslibrary", isDirectory: true)
    }
    private func database() throws -> Catalog {
        if let catalog { return catalog }
        // Use the shared layout rather than assuming the database filename when opening older libraries.
        let layout = LibraryLayout(packageURL: libraryURL)
        let db = FileManager.default.fileExists(atPath: layout.databaseURL.path)
            ? try Catalog.open(at: libraryURL) : try Catalog.create(at: libraryURL)
        catalog = db
        return db
    }
    func photos() throws -> [MobilePhoto] {
        let db = try database()
        return try db.assets().map { a in
            MobilePhoto(id: a.id, name: a.filename, url: try db.fileURL(for: a), rating: a.rating,
                        width: a.width ?? 0, height: a.height ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func importPhotos(_ urls: [URL], skipDuplicates: Bool,
                      progress: @Sendable @escaping (String, Double?) -> Void) throws -> ImportSummary {
        let grants = urls.map(FileAccess.init)
        defer { withExtendedLifetime(grants) {} }
        let service = ImportService(catalog: try database())
        service.shouldCancel = { Task.isCancelled }
        return try service.run(sources: urls, options: .init(mode: .copy, skipDuplicates: skipDuplicates),
                               onFile: { n,total in progress("Importing \(n) of \(total)", Double(n) / Double(max(1,total))) })
    }
    func edit(_ id: String) throws -> EditModel { try database().develop(forAsset: id) }
    func history(_ id: String) throws -> EditHistory {
        try database().editHistory(forAsset: id, maxDepth: UserDefaults.standard.integer(forKey: "photons.historyDepth").nonzeroOr20)
    }
    func save(_ edit: EditModel, history: EditHistory, id: String) throws {
        _ = try database().saveDevelop(edit, history: history, forAsset: id)
    }
    func rating(_ rating: Int, id: String) throws { try database().setRating(rating, forAsset: id) }
    func importedEdit(_ id: String) throws -> EditModel { try database().importedDevelop(forAsset: id) ?? .neutral }
    func releaseWorkingMemory() { graph = nil; graphKey = ""; cachedFrames.removeAll(); cacheOrder.removeAll(); context.clearCaches() }

    private func renderKey(_ photo: MobilePhoto, _ edit: EditModel, hdr: Bool, edge: Int) throws -> String {
        let data = try JSONEncoder().encode(edit)
        return SHA256.hash(data: Data("ipad-v1:\(photo.id):\(hdr):\(edge):".utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }
    func frame(_ photo: MobilePhoto, edit: EditModel, hdr: Bool, edge: Int = 1600) throws -> MobileFrame {
        try Task.checkCancellation()
        let key = try renderKey(photo, edit, hdr: hdr, edge: edge)
        if let hit = cachedFrames[key] { return hit }
        let pixels = try render(photo.url, edit: edit, edge: edge, hdr: hdr, histogram: true)
        guard let display = pixels.display else { throw MobileError.message("The renderer returned no image.") }
        let image = try displayImage(display)
        let frame = MobileFrame(image: image, histogram: pixels.histogram)
        cachedFrames[key] = frame; cacheOrder.append(key)
        while cacheOrder.count > 8 { cachedFrames.removeValue(forKey: cacheOrder.removeFirst()) }
        return frame
    }
    /// Grid thumbnails and their histogram are persisted together. Selecting an unchanged photo
    /// never recomputes its histogram just to populate the inspector.
    func thumbnail(_ photo: MobilePhoto, hdr: Bool) throws -> MobileFrame {
        let edit = try self.edit(photo.id), key = try renderKey(photo, edit, hdr: hdr, edge: 320)
        let dir = libraryURL.appendingPathComponent("MobilePreviews", isDirectory: true)
        let jpg = dir.appendingPathComponent(key + ".jpg"), hist = dir.appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: hist), let histogram = try? JSONDecoder().decode(Histogram.self, from: data),
           let src = CGImageSourceCreateWithURL(jpg as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return MobileFrame(image: image, histogram: histogram)
        }
        let frame = try frame(photo, edit: edit, hdr: hdr, edge: 320)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let destination = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, frame.image, nil)
            if CGImageDestinationFinalize(destination), let histogram = frame.histogram {
                try JSONEncoder().encode(histogram).write(to: hist, options: .atomic)
            }
        }
        return frame
    }
    private func render(_ url: URL, edit: EditModel, edge: Int, hdr: Bool, histogram: Bool,
                        linear: Bool = false) throws -> RenderResult {
        let size = try sourceSizes[url] ?? ImageSourceDecoder.size(at: url)
        sourceSizes[url] = size
        let scale = edge > 0 ? min(1, Float(edge) / Float(max(size.width, size.height))) : 1
        let inputs = edit.decodeInputs
        let key = url.path + inputs.key + ":\(scale)"
        if graphKey != key || graph == nil {
            graph = nil
            let image: LinearImage
            let input: RenderInput
            if ImageSourceDecoder.isRAW(url) {
                let result = try RAWDecoder().decodeDetailed(url, options: .init(decoderVersion: inputs.decoderVersion,
                    scale: scale, whiteBalance: inputs.whiteBalance, detail: inputs.detail))
                image = result.image
                input = RenderInput(image: image, identity: key, sourceURL: url, lensProfile: result.lensProfile,
                                    whiteBalance: inputs.whiteBalance, asShotPair: result.asShotWhiteBalance)
            } else {
                image = try ImageSourceDecoder.decodeRaster(url, scale: scale)
                input = RenderInput(image: image, identity: key, sourceURL: url)
            }
            graphSize = ImageSize(width: image.uprightSize.width, height: image.uprightSize.height)
            graph = try RenderGraph(input: input, cacheBudgetBytes: 160_000_000)
            graphKey = key
        }
        try Task.checkCancellation()
        return try graph!.render(edit, options: RenderOptions(
            display: .init(primaries: .displayP3, bitDepth: 16, headroom: hdr ? 16 : 1,
                           linearOutput: linear, sdrProof: !hdr),
            wantsPixels: true, collectHistogram: histogram, histogramSampleLongEdge: 192))
    }
    private func displayImage(_ display: DisplayImage) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.extendedDisplayP3)!
        let data = display.rgba.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: display.width * 8,
                            size: CGSize(width: display.width, height: display.height), format: .RGBAh, colorSpace: space)
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: space) else {
            throw MobileError.message("Could not create the preview.")
        }
        return cg
    }
    func frame(_ plan: PanoramaPlan, hdr: Bool) throws -> MobileFrame {
        guard let preview = plan.preview else { throw MobileError.message("No composite preview was produced.") }
        let linear = CIImage(cgImage: preview)
        let projected = hdr ? linear : SDRProjection.image(linear)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        guard let image = context.createCGImage(projected, from: projected.extent, format: .RGBAh, colorSpace: space) else {
            throw MobileError.message("Could not display the composite.")
        }
        let scale = min(1,192 / max(linear.extent.width, linear.extent.height))
        let small = linear.transformed(by: CGAffineTransform(scaleX: scale,y: scale))
        let w = max(1,Int(small.extent.width)), h = max(1,Int(small.extent.height))
        var pixels = [Float16](repeating: 0,count: w*h*4)
        context.render(small,toBitmap: &pixels,rowBytes: w*8,bounds: CGRect(x: 0,y: 0,width: w,height: h),
                       format: .RGBAh,colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let snapshot = HistogramSnapshot(sample: LinearSample(width: w,height: h,rgba: pixels),
                                         canvas: ImageSize(width: Int(plan.outputSize.width),height: Int(plan.outputSize.height)))
        return MobileFrame(image: image,histogram: snapshot.histogram(hdr: hdr,headroom: hdr ? 16 : 1))
    }
    func profiles() throws -> [LCCProfileSummary] {
        let store = LCCProfileStore(); try store.installBundledProfile(); return store.catalog().profiles
    }
    func importProfile(_ url: URL) throws {
        let lease = FileAccess(url); defer { withExtendedLifetime(lease) {} }
        let profile = try LCCProfileCodec.decode(Data(contentsOf: url))
        _ = try LCCProfileStore().importProfile(profile, keepingBoth: true)
    }
    func sourceInfo(_ photos: [MobilePhoto]) throws -> [PanoramaSource] { try photos.map { try PanoramaSource(url: $0.url) } }
    func analyze(_ photos: [MobilePhoto], options: PanoramaOptions, positions: [Int: CGPoint],
                 sensor: SensorSize?, registrationMode: PanoramaRegistrationMode = .shift, cancellation: PanoramaCancellation,
                 progress: @Sendable @escaping (String, Double?) -> Void) throws -> PanoramaPlan {
        releaseWorkingMemory()
        return try PanoramaEngine().analyze(urls: photos.map(\.url), options: options, knownPositions: positions,
            sensorOverride: sensor, registrationMode: registrationMode, cancellation: cancellation, progress: { progress($0, nil) })
    }
    func correct(_ photo: MobilePhoto, flat: URL?, profileID: UUID?, position: CGPoint?, refine: Bool,
                 body: PanoramaCameraBody, orientation: PanoramaBodyOrientation,
                 cancellation: PanoramaCancellation,
                 progress: @Sendable @escaping (String, Double?) -> Void) throws -> (PanoramaPlan, PanoramaManifest?) {
        releaseWorkingMemory()
        let scene = try PanoramaSource(url: photo.url)
        if let flat {
            guard scene.isRAW, ImageSourceDecoder.isRAW(flat) else { throw MobileError.message("Traditional LCC requires a Bayer RAW photograph and its matching RAW flat. Use a lens profile for rendered photographs.") }
            let lease = FileAccess(flat); defer { withExtendedLifetime(lease) {} }
            return (try LCCCorrectionEngine.traditional(scene: scene, flatURL: flat, cancellation: cancellation,
                                                       progress: { progress($0, nil) }), nil)
        }
        guard let profileID else { throw MobileError.message("Choose a lens profile first.") }
        let profile = try LCCProfileStore().load(profileID)
        if let manifest = try PanoramaManifest.read(from: photo.url), manifest.frames.count > 1 {
            let result = try LCCCorrectionEngine.postProcess(scene: scene, manifest: manifest, profile: profile,
                offset: position.flatMap { manifest.offset(pictureCenter: $0) }, cameraBody: body,
                cancellation: cancellation, progress: { progress($0, nil) })
            return (result.plan, result.manifest)
        }
        return (try LCCCorrectionEngine.single(scene: scene, profile: profile, position: position, refine: refine,
            body: body, orientation: orientation, cancellation: cancellation, progress: { progress($0, nil) }).plan, nil)
    }
    func correctPanorama(_ plan: PanoramaPlan, profileID: UUID, offset: CGPoint?, body: PanoramaCameraBody,
                         orientation: PanoramaBodyOrientation, cancellation: PanoramaCancellation,
                         progress: @Sendable @escaping (String, Double?) -> Void) throws -> PanoramaPlan {
        guard plan.registrationMode != .perspective else { throw MobileError.message(PanoramaRegistrationMode.perspectiveLCCNotice) }
        guard let sensor = plan.sources.first?.sensor else { throw MobileError.message("Sensor dimensions are required for LCC.") }
        let engine = PanoramaEngine(), profile = try LCCProfileStore().load(profileID)
        let fields = try LCCCorrectionEngine.fields(profile, cancellation: cancellation)
        let prepared = try engine.prepareLCCImages(plan, cancellation: cancellation, progress: { progress($0, nil) })
        let origin = try offset ?? LCCPositionSolver.solve(plan: prepared, fields: fields, sensor: sensor,
            cameraBody: body, bodyOrientation: orientation, cancellation: cancellation, progress: { progress($0, nil) }).offsetMM
        return try engine.applyingLCC(prepared, profile: profile, fields: fields, offsetMM: origin,
            sensor: sensor, crop: false, cancellation: cancellation, cameraBody: body, bodyOrientation: orientation)
    }
    func createProfile(name: String, frames: [LCCCreationFrame], sensor: SensorSize,
                       cancellation: PanoramaCancellation, progress: @Sendable @escaping (String, Double?) -> Void) throws {
        let profile = try LCCProfileBuilder.create(name: name, aperture: nil, notes: "User-created iPad profile",
            frames: frames, sensorLongEdge: max(sensor.width, sensor.height), sensorShortEdge: min(sensor.width, sensor.height),
            cancellation: cancellation, progress: { progress($0, nil) })
        _ = try LCCProfileStore().save(profile)
    }
    func export(photo: MobilePhoto?, edit: EditModel, plan: PanoramaPlan?, manifest: PanoramaManifest?,
                settings: MobileExportSettings, cancellation: PanoramaCancellation,
                progress: @Sendable @escaping (String, Double?) -> Void) throws -> URL {
        let dir = libraryURL.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = plan.map { $0.sources.count > 1 ? PanoramaManifest.defaultName($0.sources.map(\.url)) : $0.sources[0].url.deletingPathExtension().lastPathComponent + "_lcc" }
            ?? photo?.url.deletingPathExtension().lastPathComponent ?? "Photo"
        let output = OutputNameAllocator().reserve(base: base, ext: settings.format == "dng" ? "dng" : settings.preset.format.fileExtension,
                                                       in: dir, policy: .rename)
        guard let output else { throw MobileError.message("Could not reserve an output filename.") }
        let temporary = dir.appendingPathComponent(".\(UUID().uuidString).\(output.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        progress("Rendering", 0.1)
        let preset = settings.preset
        if let plan {
            let scene = try PanoramaEngine().renderComposite(plan, cancellation: cancellation, outputLongEdge: settings.longEdge > 0 ? settings.longEdge : nil,
                                                             progress: { progress($0, nil) })
            let packet = try (manifest ?? PanoramaManifest(plan: plan)).encoded()
            if settings.format == "dng" {
                try LinearDNGWriter.write(image: scene, context: context, to: temporary, manifest: packet,
                                          cancellation: cancellation, progress: { progress($0, nil) })
            } else {
                let rendered = try PanoramaPixelRenderer.render(scene: scene, preset: preset, progress: progress)
                try writeRendered(rendered, to: temporary, preset: preset, packet: packet)
            }
        } else if let photo {
            let result = try render(photo.url, edit: edit, edge: settings.longEdge, hdr: settings.hdr,
                                    histogram: false, linear: settings.hdr || settings.format == "dng")
            guard let display = result.display else { throw MobileError.message("The renderer returned no pixels.") }
            let linear = LinearPixels(width: display.width, height: display.height, rgba: display.rgba, primaries: .displayP3)
            let packet = try PanoramaManifest.read(from: photo.url)?.encoded()
            if settings.format == "dng" {
                let data = display.rgba.withUnsafeBytes { Data($0) }
                let image = CIImage(bitmapData: data, bytesPerRow: display.width * 8, size: CGSize(width: display.width, height: display.height),
                                    format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
                var item = ExportItem(id: photo.id, name: photo.name, edit: edit, sourceURL: photo.url)
                item.panoramaMetadata = packet
                let adjusted = try PanoramaExportMetadata.data(for: item, source: nil, trimX: 1, trimY: 1, sourceSize: sourceSizes[photo.url])
                try LinearDNGWriter.write(image: image, context: context, to: temporary, manifest: adjusted, cancellation: cancellation,
                                          progress: { progress($0, nil) })
            } else {
                let rendered = settings.hdr ? linear.displaySDR(bitDepth: preset.effectiveBitDepth, toneMap: .global) : display
                try writeRendered(rendered, to: temporary, preset: preset, packet: packet, photo: photo, edit: edit)
            }
        } else { throw MobileError.message("Select a photo first.") }
        try cancellation.check()
        try FileManager.default.moveItem(at: temporary, to: output)
        progress("Importing output", 0.95)
        let imported = try importPhotos([output], skipDuplicates: true, progress: { _,_ in })
        guard imported.failed == 0 else { throw MobileError.message("Saved \(output.lastPathComponent) in Documents/Exports, but automatic library import failed. You can import the saved file again.") }
        progress("Export complete", 1)
        releaseWorkingMemory()
        return output
    }
    private func writeRendered(_ original: DisplayImage, to url: URL, preset: ExportPreset,
                               packet: Data?, photo: MobilePhoto? = nil, edit: EditModel? = nil) throws {
        var image = original
        if preset.hdrKind == .gainMap, preset.hdr?.halfSize == true {
            let crop = GainMapSizing.plan(image.size, halfSize: true).crop
            if crop.isNeeded { image = GainMapSizing.crop(image, crop) }
        }
        let source = SourceMetadata.read(from: photo?.url)
        var item = ExportItem(id: photo?.id ?? "panorama", name: photo?.name ?? "Panorama", edit: edit, sourceURL: photo?.url)
        item.panoramaMetadata = packet
        var metadata = ExportMetadataContext(source: source, edit: edit, embedXMP: edit != nil)
        metadata.panoramaData = try PanoramaExportMetadata.data(for: item, source: source,
            trimX: Double(image.width) / Double(original.width), trimY: Double(image.height) / Double(original.height),
            sourceSize: photo.flatMap { sourceSizes[$0.url] })
        try Exporter.write(image, to: url, options: preset.exportOptions, metadata: metadata)
    }
}
enum MobileError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
private extension Int { var nonzeroOr20: Int { [10,20,50,100].contains(self) ? self : 20 } }
#endif
