# Photons Studio 0.3.0 (8) · TIFF 与 TestFlight

| 追踪编号 | 验收目标 | 依赖 |
| --- | --- | --- |
| TIFF-COMP-01 | Mac 和 iPad 的 TIFF 导出可选压缩方式，默认 ZIP | fork 本地 main 的 95ece26 |
| TF-MAC-01 | 上传 Mac 分发构建，分配 Developer Beta 和 Private Beta | TIFF-COMP-01 |
| TF-IPAD-01 | 上传 iPad 分发构建，分配 Developer Beta 和 Private Beta | TIFF-COMP-01 |

## TIFF-COMP-01

普通照片与接片均支持 ZIP、LZW、不压缩，8 位 SDR 且长边不超过 30,000 像素时也可选有损 JPEG 及质量。ZIP 用 Adobe Deflate。Mac 预设可保存选项，旧预设缺少该字段时使用 ZIP。文件大小估算随选择变化。两端分别在 ExportSheet 与 MobileTools 中设置选项，共用 PhotonsCore 的 TIFFCompression、PhotonsExport 的 SDR/HDR 编码器和预设。PanoramaEngine 的独立 16 位 TIFF 输出也默认 ZIP。

在 Mac 用中文界面运行 swift test，选中 HDRFormatTests、ExportFileSizeEstimateTests、ExportPresetTests、ExportSheetModelTests 和 PanoramaTests.testPreviewAndFullRenderUseSameTopLeftPlan，66 项通过。逐项读回文件与内存结果，验证压缩标签、8/16 位位深及无损像素一致性，覆盖 SDR、PQ 和 HLG。iPad Pro 13 英寸模拟器通过 IPadEngineTests.testTIFFCompressionOnPhotoExport 与 testPanoramaAlignmentScaledLosslessExportAndMetadata 两项。第一次 iPad 测试发现输入 XMP 的 tiff:Compression 会覆盖输出选项，修复后两端均使用含旧压缩标签的素材复验。没有进行 Photoshop 或 iPad 真机手测。

本项没有移植外部提交，可独立回退。后续两份归档依赖本项。具体功能提交可用 git log --grep=TIFF-COMP-01 定位。
