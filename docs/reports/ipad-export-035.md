# iPad 预览缓存与双端导出核查

基线为 505174f，产品版本 0.3.5。

## IPAD-CACHE-02 · 字节预算 LRU

在 arm64 iPadOS 27.2 模拟器用优化编译的 Swift 比较生产缓存顺序维护与带时间戳、定期压缩的候选队列。两者都执行相同的最近使用淘汰。用轻量载荷隔离索引成本，40,000 次混合读写、超预算替换与清空得到相同的读回结果和字节计数。每个场景交替跑九轮，每轮 100,000 次，以下是每次操作中位纳秒数。

| 驻留项 | 命中，现有 / 候选 | 滚动插入淘汰，现有 / 候选 |
| --- | --- | --- |
| 3 | 114 / 170 | 345 / 360 |
| 14 | 243 / 183 | 518 / 396 |
| 32 | 894 / 235 | 749 / 468 |
| 128 | 3464 / 240 | 1984 / 512 |

以 320 × 240 的两张 RGBAh 预览为例，16 MiB 缩略图预算约能驻留 13 对。候选在接近这一容量时每次省约 0.06–0.12 微秒，在少量大图的工作集上更慢。保留现有实现，大图库预热时挑选待生成照片是另一段代码。未测物理 M1 或整库解码耗时。本机实验在 local/out/ipad-export-035。

## EXPORT-2020-01 · 双端导出色域

HDR、TIFF、线性 DNG 的初始色域为 Rec.2020。Mac 保留显式指定的预设色域，iPad 按格式自动设置。iPad 单张导出在选定色域渲染，DNG 的 16 位像素和 D65 颜色矩阵、D50 前向矩阵使用同一组基色，缩略图使用 sRGB。修改涉及 PhotonsCore、Export、Panorama、Jobs、UI 与 Mobile，无前置功能依赖。

本次 Mac 执行 HDRColorSpaceTests、ExportPresetTests、ExportSheetModelTests 和全景 DNG 回读测试。iPadOS 模拟器实际导出并读回四种 TIFF 压缩选项的位深、压缩标记和 Rec.2020 描述，拼接 DNG 缩放及元数据测试通过。未进行物理屏幕色彩测量。

## IPAD-ICON-01 · iPad 主屏图标

原 1024 像素 PNG 把四边黑底和 Mac 圆角一起烘进了图片。iPad 应用目标现在直接引用已有的 Resources/AppIcon.icon 分层图稿，Xcode 为 iPad 编译外观和旧系统的 76 pt 图标。移除仅含旧 PNG 的 iPad 资源目录。Mac 图稿无修改。独立改动。

本次 xcodebuild 模拟器构建成功，安装 Studio 后在 iPadOS 27.2 主屏截屏验证。屏上同时有使用旧图标的 Photons Preview 和新 Studio，前者有黑框，新版黄色底色延伸至系统圆角。截图 local/out/ipad-export-035/home.png。未运行 iPadOS 18 真机。
