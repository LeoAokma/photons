import PhotonsLocalization
import PhotonsPanorama
import SwiftUI

public struct LCCProfileMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var apertureText: String
    @State private var notes: String
    @State private var saving = false
    @State private var error: String?
    private let save: @MainActor (String, Double?, String) async throws -> Void

    public init(profile: LCCLensProfile, save: @escaping @MainActor (String, Double?, String) async throws -> Void) {
        _name = State(initialValue: profile.name)
        _apertureText = State(initialValue: profile.aperture.map {
            let text = String($0)
            let compact = text.hasSuffix(".0") ? String(text.dropLast(2)) : text
            return compact.replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
        } ?? "")
        _notes = State(initialValue: profile.notes)
        self.save = save
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var apertureInput: String { apertureText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var aperture: Double? {
        let decimal = Locale.current.decimalSeparator ?? "."
        return Double(apertureInput.replacingOccurrences(of: decimal, with: "."))
    }
    private var validAperture: Bool {
        apertureInput.isEmpty || aperture.map { $0.isFinite && $0 > 0 && $0 <= 128 } == true
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("lcc.profile.editTitle")).font(.title2.bold())
            Form {
                TextField(L10n.tr("d44e9b3d3b31"), text: $name)
                    .accessibilityIdentifier("profile-edit-name")
                LabeledContent(L10n.tr("lensInfo.aperture")) {
                    HStack(spacing: 4) {
                        Text("f/")
                        TextField(L10n.tr("ipad.b37c7879f6c3"), text: $apertureText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .frame(width: 80)
                            .accessibilityLabel(L10n.tr("lensInfo.aperture"))
                            .accessibilityIdentifier("profile-edit-aperture")
                    }
                }
                if !validAperture { Text(L10n.tr("95069b4fdd7d")).foregroundStyle(.red) }
                TextField(L10n.tr("ipad.8a7525b1492f"), text: $notes, axis: .vertical)
                    .lineLimit(2...5).accessibilityIdentifier("profile-edit-notes")
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.tr("2cd0f3be8738")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("a3030bf8f16d")) {
                    saving = true
                    Task { @MainActor in
                        do { try await save(trimmedName, aperture, notes); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("profile-save-metadata")
                .disabled(trimmedName.isEmpty || trimmedName.count > 200 || !validAperture || notes.count > 8000)
            }
        }
        .padding(20)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        #if os(macOS)
        .frame(width: 440)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
