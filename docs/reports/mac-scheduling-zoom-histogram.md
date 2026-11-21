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

## PANO-HIST-01

旧版给接片预览中的直方图留了 126 pt 内容高度，实际 RGB 行结束于 90 pt。fork main 中的 `55faa84` 已使用内容高度，加上上下各 6 pt 内边距，浮层从 138 pt 收到 102 pt。曲线、削顶和 RGB 读数保持原尺寸。

本次在 `PanoramaHDRTests` 增加接片窗口布局验收，在真实 SwiftUI 宿主中绘制 AppKit 直方图，核对内容底边与读数行底边、以及浮层的位置。临时恢复旧高度，单项测试按预期报出 126 与 90 不相等；恢复 main 后运行 `swift test --filter 'HistogramCardHeightTests|PanoramaHDRTests'`，14 项通过，无跳过。使用合成 HDR 图像。测试可独立回退，生产布局位于 `PanoramaHDRPreview.swift`。
