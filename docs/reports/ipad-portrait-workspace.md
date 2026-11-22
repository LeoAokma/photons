# iPad 竖屏照片工作区

## IPAD-FIT-01 · 按转正后的照片尺寸适配

CIRAWFilter 的 nativeSize 描述传感器方向，输出图像已按拍摄方向转正。在 11 英寸 iPad Pro 模拟器上复现：存储为 320 × 240、带 90° 方向标记的 DNG 实际显示为 240 × 320。在 794 × 1,090 点的画布中，旧 Fit 把照片宽度缩到了 446.6 点，修复后为 794 点。

ImageSourceDecoder 的 RAW 尺寸查询现在读取解码时使用的 RAW 滤镜，并使用滤镜方向换算宽高。裁切、编辑旋转、细节窗口和缩略图由同一正向几何计算。iPad 预览缓存键升级，旧版缓存会在下次访问照片时重新生成，一次生成后 SDR、HDR 都可复用。原片和用户编辑无需迁移。

复现与验证均使用生成的 DNG。回归覆盖 EXIF 1、5、6、7、8，90° 编辑旋转和非对称裁切，分别检查第一次生成的 HDR 预览、重新打开磁盘缓存后的 SDR 预览及 Fit。此次还在 11 英寸 iPad Pro (M5) 模拟器运行细节像素和双击缩放 UI 测试；3 项均通过。独立改动，无前序依赖或外部移植。

提交 `0435bfd`。主要文件为 `ImageSourceDecoder.swift`、`MobileEngine.swift` 和 `IPadEngineTests.swift`。

## IPAD-ADJUST-02 · 在窄窗口把调整面板放在照片下方

iPad 工作区沿用 950 点的窗口宽度分界。较窄时，工具栏的调整按钮展开底栏，照片或网格继续显示在上方。底栏使用工作区高度的 36%，最高 400 点。11 英寸竖屏可在左侧看直方图，同时滚动右侧的调整项。低于 600 点宽时，直方图随调整内容滚动。宽窗口使用右侧栏。旋转设备会保留当前调整页、编辑和手动选择的面板开关状态。

主要文件为 `MobileWorkspaceView.swift`、`MobileInspector.swift`、中英文快速入门文案及 `IPadUITests.swift`。此项独立可回退，与 `0435bfd` 一起验证，无外部移植。按 `git log --grep=IPAD-ADJUST-02 -- Sources/PhotonsMobile/MobileWorkspaceView.swift` 可定位本节对应提交。

本次用 `xcodebuild test` 在 11 英寸 iPad Pro (M5) 模拟器验证底栏位于照片或网格下方、调节色温、旋转照片、恢复 Fit、横竖屏转换保留当前编辑页、收起底栏后恢复画布，以及网格选中和双击打开。相关三个 UI 用例均通过。13 英寸 iPad Pro (M5) 模拟器的宽屏网格与侧栏、快速入门语言切换两个用例通过。尚未在实体 iPad 或低于 600 点的分屏窗口复测。

macOS 的 `swift build -c release` 和通用 iPadOS 设备目标的 `xcodebuild build -configuration Release` 均通过。两端本地产物位于 `local/out/studio-035-ipad-portrait/`。iPad 设备产物为未签名的 0.3.5 (8)。测试日志、展开与收起底栏的截图在 `local/out/ipad-portrait-035/`。
