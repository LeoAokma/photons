import SwiftUI
import PhotonsExport
import PhotonsLocalization

struct ExportFileSizeLabel: View {
    let estimate: ExportFileSizeEstimate?
    var identifier = "export.estimatedSize"
    var body: some View {
        Text(ExportFileSizeText.summary(estimate))
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .help(ExportFileSizeText.summary(estimate) + "\n" + L10n.tr("export.estimatedSize.hint"))
            .accessibilityIdentifier(identifier)
    }
}
