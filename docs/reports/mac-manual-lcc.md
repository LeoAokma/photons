# Mac 手动 LCC 对齐与 SDR 导出回读

基线 1388162，版本 0.3.5。MAC-LCC-PREVIEW-01 统一对齐预览与提交；MAC-LCC-MANUAL-01 在其上增加独立手动入口和位置保留；EXPORT-2020-TRC-01 单独核对双端 SDR Rec.2020 输出。

## MAC-LCC-PREVIEW-01 · 应用窗口中已看到的结果

旧编辑器在拖动时跳过裁切与接缝重算，并沿用上次白平衡。点击应用后再次运行另一组参数，得到的图有可能与刚确认的画面不同。现在拖动或输入毫米数后按主窗口选择的裁切、接缝和白平衡生成完整预览，裁切后的图放在对应的全景坐标上。应用直接移交已显示的 PanoramaPlan；过期、失败或仍在生成的预览不能提交。编辑器以主窗口的 sheet 打开，避免后台变更被旧窗口覆盖。

本次运行 PanoramaManualLCCTests、LCCCorrectionTests、LCCPositionReferenceTests，共 5 项通过。用两张生成的 TIFF 和渐变标定场实测 (7, −2) mm、启用裁切；核对主窗口收到同一 CGImage、后台任务写出的 sRGB TIFF 的裁切、位置及三处 RGB 回读。实际照片上的位置取决于用户选择。发现默认 SDR Rec.2020 描述与像素传递曲线不符，另列 EXPORT-2020-TRC-01 验证。
