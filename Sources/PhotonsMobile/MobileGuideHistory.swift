#if os(iOS)
import Foundation

/// Completion belongs to an installed app version/build, never to the photo library.
struct MobileGuideHistory {
    let defaults: UserDefaults
    private let key = "photons.mobile.guide.seenBuilds"
    func hasSeen(_ build: String) -> Bool { (defaults.stringArray(forKey: key) ?? []).contains(build) }
    func markSeen(_ build: String) {
        var builds = defaults.stringArray(forKey: key) ?? []
        guard !builds.contains(build) else { return }
        builds.append(build); defaults.set(builds,forKey: key)
    }
    static var currentBuild: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo"),
           let build = ProcessInfo.processInfo.environment["PHOTONS_GUIDE_TEST_BUILD"] { return build }
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
    static var launchHistory: Self {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            return .init(defaults: UserDefaults(suiteName: "com.leoaokma.photons.guide-demo")!)
        }
        #endif
        return .init(defaults: .standard)
    }
    static var automaticPresentationEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            return ProcessInfo.processInfo.arguments.contains("--test-onboarding")
        }
        #endif
        return true
    }
}
#endif
