#if os(iOS)
import SwiftUI

struct MobileCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3).foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                configuration.label.foregroundStyle(.primary)
                Spacer(minLength: 0)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
#endif
