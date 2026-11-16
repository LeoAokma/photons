import AppKit
import SwiftUI
import Metal
import PhotonsCore

/// A process-wide target keeps ⌘, working with an export/tool window in front, too.
@MainActor
public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 550),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        super.init(window: window)
        window.center()
        window.setFrameAutosaveName("PhotonsSettings")
    }
    public required init?(coder: NSCoder) { fatalError("no nib") }

    @objc public func openSettings(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case workspace, hdr, performance
    var id: String { rawValue }
    var title: String {
        switch self { case .workspace: return "工作区"; case .hdr: return "HDR 与预览"; case .performance: return "性能与降噪" }
    }
    var symbol: String {
        switch self { case .workspace: return "rectangle.3.group"; case .hdr: return "sun.max"; case .performance: return "cpu" }
    }
    var subtitle: String {
        switch self {
        case .workspace: return "让界面适合你的看图与编辑习惯。"
        case .hdr: return "管理屏幕上的高光显示。"
        case .performance: return "平衡后台处理速度、内存与能耗。"
        }
    }
}

private struct SettingsView: View {
    @State private var page: SettingsPage = .workspace
    @Bindable private var preferences = ApplicationPreferences.shared
    @State private var backdrop = CanvasBackdrop.current
    @State private var concurrency = ProcessingPreferences.thumbnailConcurrency
    private let deviceName = MTLCreateSystemDefaultDevice()?.name

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PHOTONS").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 22)
                ForEach(SettingsPage.allCases) { item in
                    Button { page = item } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 12, weight: page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(page == item ? Color.primary.opacity(0.09) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("settings.page.\(item.rawValue)")
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
                Text("设置自动保存").font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
            }
            .padding(.horizontal, 12).frame(width: 172)
            .background(Color(nsColor: StudioTheme.panel))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(page.title).font(.system(size: 23, weight: .semibold))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch page {
                        case .workspace: workspace
                        case .hdr: hdr
                        case .performance: performance
                        }
                    }.padding(.top, 20).padding(.bottom, 16)
                }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: StudioTheme.raised))
        .onReceive(NotificationCenter.default.publisher(for: .canvasBackdropDidChange)) { _ in
            backdrop = CanvasBackdrop.current
        }
        .onReceive(NotificationCenter.default.publisher(for: .photonsPreferencesDidChange)) { _ in refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in refreshStatus() }
    }

    private var workspace: some View {
        Group {
            group("外观") {
                Picker("界面", selection: $preferences.appearance) {
                    ForEach(WorkspaceAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("settings.appearance")
                Text("中性的界面背景，便于判断照片的色彩与明暗。").settingsHint()
            }
            group("画布") {
                Picker("照片周围的背景", selection: Binding(get: { backdrop }, set: {
                    backdrop = $0; CanvasBackdrop.set($0)
                })) {
                    Text("深灰").tag(CanvasBackdrop.dark)
                    Text("中灰").tag(CanvasBackdrop.midGrey)
                    Text("浅灰").tag(CanvasBackdrop.light)
                }.accessibilityIdentifier("settings.canvasBackdrop")
                Text("立即应用于主画布和素材浏览区。").settingsHint()
            }
            group("启动") {
                Toggle("重新打开上次使用的照片库", isOn: $preferences.reopenLibrary)
                    .accessibilityIdentifier("settings.reopenLibrary")
            }
        }
    }

    private var hdr: some View {
        Group {
            group("显示预览") {
                Toggle("启用 HDR 预览", isOn: $preferences.hdrPreview)
                    .accessibilityIdentifier("settings.hdrPreview")
                Text("在支持的显示器上显示超出 SDR 白色的高光，立即应用于单图、缩略图与全景预览。关闭后使用 SDR 显示。")
                    .settingsHint()
            }
            group("工作流") {
                Label("原始图像与导出保持独立", systemImage: "photo.badge.checkmark")
                Text("这个开关只改变屏幕预览，不修改照片参数。HDR 导出仍在导出面板中选择格式、色彩空间与 HDR 编码。")
                    .settingsHint()
                Text("可显示的高光范围取决于屏幕、亮度和系统当前提供的余量。").settingsHint()
            }
        }
    }

    private var performance: some View {
        Group {
            group("后台处理") {
                Picker("性能策略", selection: $preferences.processing) {
                    ForEach(ProcessingPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("settings.processing")
                Text("自动平衡：适度并发，低电量模式下收敛至单任务。性能优先：允许更多并行任务。节能：逐张生成缩略图。高温时所有策略都会降低并发。")
                    .settingsHint()
                LabeledContent("当前缩略图并发上限", value: "\(concurrency)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            group("硬件加速") {
                LabeledContent("显影与显示", value: deviceName == nil ? "Metal 不可用" : "Metal GPU · 已启用")
                if let deviceName { Text(deviceName).settingsHint() }
                Text("显影引擎使用 Metal；此版本没有完整的 CPU 显影后端。").settingsHint()
                Divider().padding(.vertical, 3)
                Toggle("AI 模型降噪使用 GPU", isOn: $preferences.denoiseGPU)
                    .disabled(deviceName == nil)
                    .accessibilityIdentifier("settings.denoiseGPU")
                Text("推荐开启。关闭后下一次模型降噪使用 CPU，主要用于兼容性排查，通常耗时更长。不会中断正在运行的任务。")
                    .settingsHint()
            }
        }
    }

    private func refreshStatus() { concurrency = ProcessingPreferences.thumbnailConcurrency }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content().font(.system(size: 13))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func settingsHint() -> some View {
        font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .lineSpacing(3)
    }
}
