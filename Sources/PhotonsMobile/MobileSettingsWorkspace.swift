#if os(iOS)
import PhotonsLocalization
import SwiftUI

/// Full-screen settings leave room for the lens/calibration workflow to grow independently.
struct MobileSettingsWorkspace: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var model: MobileWorkspaceModel
    @AppStorage("photons.language") private var languagePreference = "system"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let _ = interfaceLocale // Rebuild plain translated strings on live language changes.
        TabView {
            NavigationStack { MobileSettingsView(model: model).toolbar { close } }
                .tabItem { Label(L10n.tr("cameraBodies.generalTab"), systemImage: "gearshape") }
            NavigationStack { MobileSettingsView(libraryOnly: true, model: model).toolbar { close } }
                .tabItem { Label(L10n.tr("ipad.260a1e306790"), systemImage: "photo.stack") }
            NavigationStack { MobileProfilesSheet(model: model).toolbar { close } }
                .tabItem { Label(L10n.tr("ipad.bf744e98a728"), systemImage: "camera.aperture") }
        }.preferredColorScheme(.dark).tint(.orange).accessibilityIdentifier("settings-workspace")
            .environment(\.locale,Locale(identifier: L10n.resolveLanguage(
                preference: ProcessInfo.processInfo.environment["PHOTONS_LANGUAGE"] ?? languagePreference,
                preferredLanguages: Locale.preferredLanguages)))
    }
    @ToolbarContentBuilder private var close: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("c0b3fbff51cc")) { dismiss() }.accessibilityIdentifier("close-settings") }
    }
}
#endif
