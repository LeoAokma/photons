#if os(iOS)
import SwiftUI

struct MobileCacheSettings: View {
    @ObservedObject var model: MobileWorkspaceModel
    @State private var usage: MobileEngine.CacheUsage?
    @State private var clearing = false
    @State private var confirm = false
    @State private var error: String?
    private func size(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value),countStyle: .file) }
    var body: some View {
        Section {
            if let usage {
                LabeledContent("On disk",value: size(usage.diskBytes)).accessibilityIdentifier("cache-disk-size")
                LabeledContent("Cached files",value: "\(usage.files)")
                    .accessibilityElement(children: .ignore).accessibilityLabel("Cached files")
                    .accessibilityValue("\(usage.files)").accessibilityIdentifier("cache-file-count")
                LabeledContent("Preview memory",value: size(usage.memoryBytes))
            } else { ProgressView("Measuring cache…") }
            Button("Refresh size") { Task { await refresh() } }.disabled(clearing)
            Button("Clear preview cache",role: .destructive) { confirm = true }
                .disabled(model.busy || clearing).accessibilityIdentifier("clear-preview-cache")
            if clearing { ProgressView("Clearing cache…") }
            if let error { Text(error).foregroundStyle(.red) }
        } header: { Text("Preview cache") } footer: {
            Text("Disk previews use up to 512 MB. Preview memory excludes images currently on screen and rendering allocations. Clearing keeps originals, edits, folders, lens profiles and exports; previews are rebuilt when needed.")
        }
        .task { await refresh() }
        .confirmationDialog("Clear preview cache?",isPresented: $confirm,titleVisibility: .visible) {
            Button("Clear cache",role: .destructive) {
                clearing = true
                Task {
                    do { try await model.clearPreviewCache(); await refresh() }
                    catch { self.error = error.localizedDescription }
                    clearing = false
                }
            }.accessibilityIdentifier("confirm-clear-cache")
        } message: { Text("Your photographs and adjustments will be kept.") }
    }
    private func refresh() async {
        do { usage = try await model.engine.cacheUsage(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
#endif
