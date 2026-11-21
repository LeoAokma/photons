# MAC-SIDEBAR-01 · Mac 启动时左栏照片数量被裁切

本次修复基于个人 fork 的 `main`（起点 `ee87944`），可独立回退。

用图库副本恢复上次的侧栏宽度 221.35 pt。窗口刚打开时，可视区域宽 209.5 pt，展开「全部照片」后 AppKit 把树列加宽到 223 pt，数量 206、121、84 的末位超出边界。拖动分隔线 1 pt 后，列才随可视区域重新对齐。

在 `Sources/PhotonsUI/BrowserPaneController.swift` 的文件夹树配置里，关闭 `NSOutlineView.autoresizesOutlineColumn`。展开层级时使用行内缩进，表格现有的列宽调整仍跟随侧栏分隔线。用户保存的宽度和文件夹展开行为沿用原设置。

## 验证

- `FolderTreeTests.testRestoringTheFolderTreeKeepsCountsInsideTheInitialSidebar` 在真实 AppKit 窗口里先布局空侧栏，再打开测试图库。旧实现首屏列宽为 224 pt，可视区域为 210 pt；展开更深层后列宽升至 252 pt。修复后分别在首屏、展开子目录、缩至最窄时检查列宽和每个数量标签，均通过。
- `PHOTONS_LANGUAGE=zh-Hans swift test --filter 'FolderTreeTests|BrowserPaneChrome423Tests|LayoutContractTests|BrowserRowLayoutTests'` 在 Apple Silicon Mac 上执行 65 项，全部通过。
- 使用 `EditorWindowController` 在独立的图库副本中选择含 84 张照片的文件夹。分别以 196、221.35 和 260 pt 开窗，三次首次显示的内容列都与实际可视宽度一致。在用户保存的宽度下，核对了 206、121、1 和 84 四个完整读数。[首屏截图](../../local/out/mac-sidebar-01/sidebar.png)
- 用 `swift build -c release` 构建本地 [Photons.app](../../local/out/mac-sidebar-01/Photons.app)。本次验证针对 macOS；未在 Intel Mac 上运行。
