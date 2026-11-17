#if os(iOS)
import Foundation
import SwiftUI

struct MobileLibraryFolder: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
}
enum MobileFolderScope: Equatable { case all, unfiled, folder(UUID) }
/// One assignment per photo, stored atomically inside the one library. Originals and edit history
/// never move when the user reorganizes folders, and removing a folder cannot remove a photograph.
struct MobileFolderIndex: Codable, Equatable, Sendable {
    var version = 1
    var folders: [MobileLibraryFolder] = []
    var assignments: [String: UUID] = [:]
    func contains(_ id: String,in scope: MobileFolderScope) -> Bool {
        switch scope {
        case .all: return true
        case .unfiled: return assignments[id] == nil
        case .folder(let folder): return assignments[id] == folder
        }
    }
    func validatedName(_ raw: String, excluding: UUID? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.contains("/"), !name.contains("\n") else {
            throw MobileError.message("Use a folder name of 1–100 characters without slashes or newlines.")
        }
        guard !folders.contains(where: { $0.id != excluding && $0.name.compare(name,options: [.caseInsensitive,.diacriticInsensitive]) == .orderedSame }) else {
            throw MobileError.message("A folder with this name already exists.")
        }
        return name
    }
}
extension MobileEngine {
    func folderIndex() throws -> MobileFolderIndex {
        let url = libraryURL.appendingPathComponent("MobileFolders.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let result = try JSONDecoder().decode(MobileFolderIndex.self,from: Data(contentsOf: url))
        guard result.version == 1, Set(result.folders.map(\.id)).count == result.folders.count,
              Set(result.assignments.values).isSubset(of: Set(result.folders.map(\.id))) else {
            throw MobileError.message("The library folder index could not be read. Your originals are unchanged.")
        }
        return result
    }
    private func saveFolders(_ value: MobileFolderIndex) throws {
        try FileManager.default.createDirectory(at: libraryURL,withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(value).write(to: libraryURL.appendingPathComponent("MobileFolders.json"),options: .atomic)
    }
    @discardableResult func createFolder(_ name: String) throws -> MobileLibraryFolder {
        var index = try folderIndex()
        let folder = MobileLibraryFolder(name: try index.validatedName(name))
        index.folders.append(folder); try saveFolders(index); return folder
    }
    func renameFolder(_ id: UUID,to name: String) throws {
        var index = try folderIndex()
        guard let position = index.folders.firstIndex(where: { $0.id == id }) else { throw MobileError.message("Folder not found.") }
        index.folders[position].name = try index.validatedName(name,excluding: id); try saveFolders(index)
    }
    func removeFolder(_ id: UUID) throws {
        var index = try folderIndex()
        index.folders.removeAll { $0.id == id }; index.assignments = index.assignments.filter { $0.value != id }
        try saveFolders(index)
    }
    func movePhotos(_ ids: Set<String>,to folder: UUID?) throws {
        var index = try folderIndex()
        guard folder == nil || index.folders.contains(where: { $0.id == folder }) else { throw MobileError.message("Folder not found.") }
        let known = Set(try photos().map(\.id))
        guard ids.isSubset(of: known) else { throw MobileError.message("A selected photograph is no longer in this library.") }
        for id in ids { index.assignments[id] = folder }
        try saveFolders(index)
    }
}

struct MobileFolderList: View {
    @ObservedObject var model: MobileWorkspaceModel
    @State private var editor: MobileFolderEditor?
    @State private var removing: MobileLibraryFolder?
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            folderButton("All photographs",icon: "square.grid.2x2",scope: .all)
            folderButton("Unfiled",icon: "tray",scope: .unfiled)
            ForEach(model.folders.folders) { folder in
                folderButton(folder.name,icon: "folder",scope: .folder(folder.id))
                    .contextMenu {
                        Button("Rename folder") { editor = .init(folder: folder) }
                        Button("Remove folder",role: .destructive) { removing = folder }
                    }
            }
            Button("New folder",systemImage: "folder.badge.plus") { editor = .init() }
                .accessibilityIdentifier("new-library-folder")
        }.disabled(model.busy)
        .sheet(item: $editor) { value in
            MobileFolderEditorView(model: model,folder: value.folder)
        }
        .alert("Remove folder?",isPresented: Binding(get: { removing != nil },set: { if !$0 { removing = nil } })) {
            Button("Remove folder",role: .destructive) { if let removing { model.removeFolder(removing.id) }; removing = nil }
            Button("Cancel",role: .cancel) { removing = nil }
        } message: { Text("The photographs will return to Unfiled. Originals and edits will be kept.") }
    }
    private func folderButton(_ title: String,icon: String,scope: MobileFolderScope) -> some View {
        Button { model.chooseFolder(scope) } label: {
            HStack {
                Label(title,systemImage: icon).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(model.photos.filter { model.folders.contains($0.id,in: scope) }.count)").font(.caption.monospacedDigit())
            }
        }.foregroundStyle(model.folderScope == scope ? Color.orange : Color.primary)
            .accessibilityLabel(title).accessibilityValue(model.folderScope == scope ? "Selected" : "Not selected")
    }
}
private struct MobileFolderEditor: Identifiable { let id = UUID(); var folder: MobileLibraryFolder? = nil }
private struct MobileFolderEditorView: View {
    @ObservedObject var model: MobileWorkspaceModel
    let folder: MobileLibraryFolder?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name",text: $name).accessibilityIdentifier("library-folder-name")
                if let error { Text(error).foregroundStyle(.red) }
                Text("Folders organize photographs inside the single iPad library. Originals are stored once.").font(.caption)
            }.navigationTitle(folder == nil ? "New folder" : "Rename folder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                do {
                                    if let folder { try await model.engine.renameFolder(folder.id,to: name) }
                                    else { _ = try await model.engine.createFolder(name) }
                                    try await model.reload(); dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("save-library-folder")
                    }
                }
        }.onAppear { name = folder?.name ?? "" }.presentationDetents([.medium,.large]).preferredColorScheme(.dark)
    }
}
#endif
