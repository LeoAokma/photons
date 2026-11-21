# Mac 设备调度、大图缩放与接片直方图

2026-11-21 核对的个人 fork 为 `LeoAokma/photons`，远端 `main` 与本地起点均为 `0ce0d21`。当时正在运行的 Mac 应用来自相邻工作目录 `Photons Main/.build/Photons.app`，其 Info.plist 中的 `PhotonsGitRevision` 为 `e536446`。

| 编号 | 验收目标 | 依赖 |
| --- | --- | --- |
| ZOOM-TAP-01 | 大图每两次连续主按钮点击切换一次 Fit 与所选倍率 | 已在 main 的 `8ccd57f`、`b44b4d4` |
| PANO-HIST-01 | Mac 接片直方图的浮层贴合曲线和读数 | 已在 main 的 `55faa84`，独立于缩放 |
| EXPORT-SCHED-01 | Mac 普通批量导出按设备资源调整并发数 | 独立于两项 UI 验收 |

## ZOOM-TAP-01 · `f96147c`

运行中的旧版在连续点击的第 2、3、4 下分别切换一次。fork main 已按系统连击计数的偶数次触发缩放。本次在 `DoubleClickParity415Tests` 增加窗口级回归，用 `NSWindow.sendEvent` 经过命中测试和画布上的手势识别器，逐击核对六次连击以及系统计数重新从一开始的下一对。生产代码位于 `LoupeCanvasView.mouseDown` 和 `LoupeController.gestureOwner`。

本次在 Mac 使用本地 RAW 素材运行 `swift test --filter 'DoubleClickParity415Tests|LoupeZoomTransitionAnimationTests|ApplicationPreferencesTests'`，15 项通过，无跳过。包含 6 项连击、6 项动画以及 3 项偏好测试。窗口测试使用合成的鼠标事件；物理鼠标和触控板未手测。此回归测试可独立回退。

## PANO-HIST-01 · `8432093`

旧版给接片预览中的直方图留了 126 pt 内容高度，实际 RGB 行结束于 90 pt。fork main 中的 `55faa84` 已使用内容高度，加上上下各 6 pt 内边距，浮层从 138 pt 收到 102 pt。曲线、削顶和 RGB 读数保持原尺寸。

本次在 `PanoramaHDRTests` 增加接片窗口布局验收，在真实 SwiftUI 宿主中绘制 AppKit 直方图，核对内容底边与读数行底边、以及浮层的位置。临时恢复旧高度，单项测试按预期报出 126 与 90 不相等；恢复 main 后运行 `swift test --filter 'HistogramCardHeightTests|PanoramaHDRTests'`，14 项通过，无跳过。使用合成 HDR 图像。测试可独立回退，生产布局位于 `PanoramaHDRPreview.swift`。

## 调度现状

下表记录每条路径允许同时处理的工作。GCD、OperationQueue、Swift actor 和图像框架管理执行线程；在这些业务路径中未发现应用指定 CPU 核心亲和性。各队列分别限流，同时运行的不同工具仍可竞争 CPU、GPU 和内存。

| 路径 | 调度方式 | 代码入口 |
| --- | --- | --- |
| Mac 图库缩略图 | 每个共享 provider 按可用逻辑处理器数减一、每 2 GiB 物理内存一项、模式上限三者取小，至少一项。自动模式至多 4，响应优先至多 8。经济模式、自动模式下低电量或任意模式下严重发热均降至 1；电量与温度变化会更新队列。 | `PhotonsUI/ApplicationPreferences.swift`、`ThumbnailProvider.swift`、`PhotonsCatalog/ThumbnailService.swift` |
| Mac 大图与直方图 | 交互渲染合并重复请求，使用串行渲染队列。直方图 CPU 计数按图像大小与可用处理器拆分，最多 8 个行块，小样本走串行。 | `PhotonsUI/LoupeController.swift`、`PhotonsCore/Histogram.swift` |
| Mac 接片、HDR、降噪 | 接片导出经独立串行队列，每个作业启动一个 helper 并等待退出，再开始下一单。HDR 合成和 Ansel 降噪有各自的子进程入口与会话运行标记。后台缩略图、普通导出和接片之间没有共享的全局配额。 | `PhotonsUI/BackgroundTasks.swift`、`CatalogSession.swift`、`PhotonsExtensions` |
| iPad | 单个工作区的重图像操作由进程内 `MobileEngine` actor 执行。网格逐张等待缩略图；前台作业暂停预热。细节层按 Metal 纹理上限与可用进程内存选择解码尺寸；真机导出前比较预计用量与进程剩余内存的 80%。 | `PhotonsMobile/MobileWorkspaceModel.swift`、`MobileEngine.swift`、`MobileDetailSizing.swift` |

## EXPORT-SCHED-01

原 Mac 导出面板与 CLI 默认每批同时处理两张全分辨率照片。现在 `PhotonsExport/BatchExport.swift` 使用当前可用逻辑处理器数与 `hw.physicalcpu` 的较小值；系统未提供物理核心数时回退到可用逻辑处理器数。有效核心数至多 4、物理内存少于 16 GiB、系统低电量或热状态为严重及以上，均一次处理一张，其他情况至多两张。Mac 设置里的经济模式也为一张。

每张图片结束后重读策略，压力变化时允许已开始的图片完成，再调整队列。压力缓解可以从一张恢复到两张。报告记录该批次用过的最高并发上限和实际峰值。CLI 省略 `--concurrency` 时跟随设备，显式指定继续支持 1–2；单项接片仍显式指定 1。模块为 `PhotonsExport/BatchExport.swift`、`PhotonsUI/ApplicationPreferences.swift`、`PhotonsUI/ExportSheet.swift` 和 `photonsctl/export.swift`。无前序功能依赖，可单独回退。

4 核和 16 GiB 是此次采用的保守阈值；当前按整机物理内存分档，未对每张 RAW 或多窗口同时运行的总内存建模。实机验证环境为 18 核、48 GiB Mac。少核设备和热状态用测试输入覆盖，未对旧款 Mac 或 iPad 真机跑性能基准。

本次验证结果如下。

- 设置 `PHOTONS_LANGUAGE=zh-Hans` 和本地 `PHOTONS_TEST_RAW`，运行 `swift test --filter 'BatchExportTests|BatchExportCancelTests|ExportSheetModelTests|ApplicationPreferencesTests|DoubleClickParity415Tests|LoupeZoomTransitionAnimationTests|HistogramCardHeightTests|PanoramaHDRTests'`。54 项 UI 测试和 33 项导出测试全部通过，无跳过。初次在英文环境运行时，已有用例中的中文字符串断言失败。新增测试覆盖低核、低内存、低电量、过热、运行中降并发与恢复、导出面板经济模式，以及真实写盘结果。
- 建立临时图书馆，引用仓库两张 HDR bracket DNG，用 `photonsctl export batch` 导出 JPEG。自动模式写出 2 张，报告上限与峰值均为 2。显式 `--concurrency 1` 写出 2 张，上限与峰值均为 1。两次均无失败。
- `xcodebuild -project Apps/iPad/PhotonsIPad.xcodeproj -scheme 'Photons iPad Preview' -destination 'platform=iOS Simulator,id=0EA297D3-D842-4ABD-B9A5-5F424D9B8457' -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build` 成功。此项检查 iPad 模拟器编译兼容性；本次没有运行 iPad UI 测试。
