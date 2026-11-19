# Mac 照片与接片预览缩放

移植来源为 iPad 单张照片查看器的像素倍率与触控交互（`1eecec9`），以及全景预览的低分辨率显示（`ca4c5c4`）。

| 追踪编号 | 范围 | 依赖 |
| --- | --- | --- |
| MAC-ZOOM-01 | 单张照片 Fit 与自选倍率切换、持久化设置及双端共用的输入范围 | `f322025` |
| MAC-ZOOM-02 | 单张照片画布的连续捏合、触屏双击和锚点 | MAC-ZOOM-01 |
| MAC-ZOOM-03 | 接片窗口的预览缩放、平移与倍率选择 | MAC-ZOOM-01、02 |

## MAC-ZOOM-01

在「显示 → 双击放大倍率」设置 50%、100%、200% 或输入 10%–800%。默认值为 100%。在 Fit 中选择只记录目标，在放大查看时选择会立即应用。鼠标双击以点击位置为锚点，下一次双击回到 Fit。原有菜单倍率、滑条、键盘档位和裁切约束继续使用原来的入口。

对 `LoupeCameraTests`、`LoupeZoomTests`、`LoupeZoomLadderTests`、`ZoomTwelveHalfPercentTests` 和 `ZoomGlassSliderTests` 执行 SwiftPM 测试，68 项中通过 67 项，跳过 1 项外部素材测试。新回归测试检查小数和范围端点、保存的目标与两次双击后的画布状态。

## MAC-ZOOM-02

Mac 单张画布接收触屏和触控板的原生捏合事件。画布、百分比和滑条随手指连续变化，手指松开时保留当前位置。鼠标和触屏的双击继续走现有工具的命中判断。裁切上限、指针锚点和键盘档位沿用 LoupeCamera。超大照片从实际 Fit 比例起步。

以 B0000591.3FR 设置 PHOTONS_TEST_RAW，在 Mac 上运行 LoupeCamera、LoupeZoom、LoupeZoomLadder、ZoomGlassSlider、ZoomTwelveHalfPercent、CropOverlayFollow、DoubleClickParity415 和单项动画测试。82 项全部通过，覆盖 107.3% 后双击回 Fit、上下限、极小 Fit、裁切及手势注册。触屏和触控板的实物手势仍需人工试用。
