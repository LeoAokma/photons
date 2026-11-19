# Mac 照片与接片预览缩放

移植来源为 iPad 单张照片查看器的像素倍率与触控交互（`1eecec9`），以及全景预览的低分辨率显示（`ca4c5c4`）。

| 追踪编号 | 范围 | 依赖 |
| --- | --- | --- |
| MAC-ZOOM-01 | 单张照片 Fit 与自选倍率切换、持久化设置及双端共用的输入范围 | `f322025` |
| MAC-ZOOM-02 | 单张照片画布的连续捏合、触屏双击和锚点 | MAC-ZOOM-01 |
| MAC-ZOOM-03 | 接片窗口的预览缩放、平移与倍率选择 | MAC-ZOOM-01、02 |

## MAC-ZOOM-01 · `b44b4d4`

在「显示 → 双击放大倍率」设置 50%、100%、200% 或输入 10%–800%。默认值为 100%。在 Fit 中选择只记录目标，在放大查看时选择会立即应用。鼠标双击以点击位置为锚点，下一次双击回到 Fit。原有菜单倍率、滑条、键盘档位和裁切约束继续使用原来的入口。

对 `LoupeCameraTests`、`LoupeZoomTests`、`LoupeZoomLadderTests`、`ZoomTwelveHalfPercentTests` 和 `ZoomGlassSliderTests` 执行 SwiftPM 测试，68 项中通过 67 项，跳过 1 项外部素材测试。新回归测试检查小数和范围端点、保存的目标与两次双击后的画布状态。

## MAC-ZOOM-02 · `52a90ca`

Mac 单张画布接收触屏和触控板的原生捏合事件。画布、百分比和滑条随手指连续变化，手指松开时保留当前位置。鼠标和触屏的双击继续走现有工具的命中判断。裁切上限、指针锚点和键盘档位沿用 LoupeCamera。超大照片从实际 Fit 比例起步。

以 B0000591.3FR 设置 PHOTONS_TEST_RAW，在 Mac 上运行 LoupeCamera、LoupeZoom、LoupeZoomLadder、ZoomGlassSlider、ZoomTwelveHalfPercent、CropOverlayFollow、DoubleClickParity415 和单项动画测试。82 项全部通过，覆盖 107.3% 后双击回 Fit、上下限、极小 Fit、裁切及手势注册。触屏和触控板的实物手势仍需人工试用。

## MAC-ZOOM-03 · Zoom the cached Mac panorama preview in final output pixels

接片窗口与单张画布共用手势和已保存的双击目标。可在接片预览右下角直接改倍率，放大后可拖动或用触控板滚动查看接缝。百分比以最终接片的输出像素和显示器的物理像素计算。预览会提示其分辨率，Metal 从现有 HDR 预览纹理采样窗口可见的区域。调整 LCC 或防伪影时，输出尺寸相同的新预览会保留查看位置。

主要实现位于 PanoramaHDRPreview、PanoramaPreviewZoom、ThumbnailMetal 和两种画布共用的 PhotoCanvasGestures。鼠标双击沿用画布自己的命中逻辑，直接触摸的双击由 AppKit 识别。触控板使用系统的放大手势事件。[Apple 手势文档](https://developer.apple.com/documentation/appkit/gestures) · [触屏专用双击设置](https://developer.apple.com/documentation/appkit/nsclickgesturerecognizer/buttonmask)

在 Mac 用 B0000591.3FR 运行三项改动的合计 100 项相关测试，全部通过。包括接片窗口的真实 AppKit 事件分派、137.5% 下的像素锚点、HDR 亮部与方向、预览纹理取样、双击回 Fit 及单张照片的裁切和滑条。窗口测试发现并修正平移识别器延迟第一次鼠标双击的问题。iPad Pro 13 英寸（M5）模拟器的原图缩放像素、双击选择倍率、接片预览提示共 3 项测试全部通过。物理触屏及触控板尚待手动试用。三个提交均可用 `git log --grep=MAC-ZOOM` 查找。
