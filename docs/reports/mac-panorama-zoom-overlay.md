# Mac 拼接预览缩放浮窗

`MAC-PANO-ZOOM-01` 将拼接预览的缩放控件改为按内容宽度显示的半透明胶囊。原先的 SwiftUI Menu 会占满底部可用空间，覆盖照片和左下角的 HDR 读数。新控件参照 iPad 的 MobilePhotoCanvas，保留 Mac 右上角的直方图，固定在预览右下角。放大后的低分辨率提示单独显示在胶囊上方，缩放控件的位置保持稳定。

在适应状态下，菜单设置双击放大的目标倍率。在放大状态下，浮窗另显示当前倍率和“适应”按钮，选择菜单倍率会立即缩放。实现位于 `Sources/PhotonsUI/PanoramaHDRPreview.swift`，布局回归测试位于 `Tests/PhotonsUITests/PanoramaHDRTests.swift`，独立于先前的配准、缓存及导航改动。以 fork main 的 `3e3d1ee` 为基线，可用 `git log --oneline --grep=MAC-PANO-ZOOM-01` 定位该提交。

## 本次验证

- `PHOTONS_LANGUAGE=zh-Hans swift test --filter 'PanoramaHDRTests|DoubleClickParity415Tests|ZoomTwelveHalfPercentTests'` 执行 22 项，全部通过。英文环境下单独复跑新增布局测试也通过。用例把预览从 600 pt 拉宽至 1,000 pt，测量原生菜单的实际宽度与右下角间距，并向原横条所在的底部中间位置发送真实窗口双击事件，验证放大和恢复适应。
- 用仓库的 DNG 样片生成两个重叠裁片，在真实拼接窗口分别检查适应和放大状态。打开原生菜单看到 50%、100%、200% 和自定义项，在放大状态选 50% 后读回缩放值 0.5，再点击“适应”后读回适应状态。截图保存在本机 `local/out/mac-pano-zoom-01/fit.png` 和 `zoom.png`。
- `swift build -c release` 成功。本次改动只涉及 Mac，无外部代码移植或回退依赖。自定义百分比输入沿用原对话框，本次实际菜单操作验证了预设倍率和适应。
