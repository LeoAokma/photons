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

## TF-IPAD-01

从 TIFF-COMP-01（`22e3cf1`）用 Photons iPad Preview scheme、Studio.xcconfig 和 Apple Distribution 描述文件归档，版本 0.3.0 (8)，包标识 com.leoaokma.photons，仅面向 iPad，最低 iPadOS 18。对归档运行 codesign --verify --deep --strict，核对二进制与 dSYM 的 UUID、两份镜头配置的哈希，以及未打包测试原片。纽约时间 02:15:17，xcodebuild -exportArchive 返回 Upload succeeded。

在内置浏览器保存中英文测试说明，把构建加入 Developer Beta 和 Private Beta 并提交外测审核。02:20 在两个组各自的 Builds 清单核实，iOS 0.3.0 (8) 均显示 **Testing**。已开启获批后自动通知。未在实体 iPad 上安装 TestFlight 包。部署提交可用 git log --grep=TF-IPAD-01 定位，回退记录不撤销 Apple 的分发。

[iPad 构建](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835570029/testflight/ios/8a5ce869-eed6-456e-a31a-2aca0a44a77c) · [Developer Beta](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835570029/testflight/groups/80db453c-65e8-44c3-a63e-7a1e5f461aa9/builds) · [Private Beta](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835570029/testflight/groups/f5df1ef4-8e90-459a-9fb3-8b23a2f39624/builds)

## TF-MAC-01

从 TIFF-COMP-01（`22e3cf1`）构建 Mac Release 与两个 vendored helper，由 scripts/testflight.py 组装沙盒应用并使用 Apple Distribution 签名。构建为 0.3.0 (8)，面向 arm64 Mac，最低 macOS 14。沙盒诊断和接片 worker 均通过，归档中主程序与三个 helper 的 dSYM UUID 均匹配，已核对签名、描述文件与两份镜头配置。纽约时间 02:16:17，xcodebuild -exportArchive 返回 Upload succeeded。

在内置浏览器保存中英文测试说明，同一次分组选中 Developer Beta 和 Private Beta，勾选自动通知并提交审核。02:21 在两组 Builds 清单再次核实，macOS 0.3.0 (8) 的 DB 状态为 **Testing**，PB 状态为 **Waiting for Review**。外测开放时间由 Apple 决定。本次未在另一台 Mac 安装 TestFlight 版本。

[Mac 构建](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835570029/testflight/macos/db9ce37d-2a17-4566-a57d-771d14c9850f) · [Developer Beta](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835570029/testflight/groups/80db453c-65e8-44c3-a63e-7a1e5f461aa9/builds) · [Private Beta](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835570029/testflight/groups/f5df1ef4-8e90-459a-9fb3-8b23a2f39624/builds)

## 提交与产物

| 编号 | Git 提交 |
| --- | --- |
| TIFF-COMP-01 | `22e3cf1` |
| TF-IPAD-01 | `8f78e7c` |
| TF-MAC-01 | 包含本节的部署记录，可用 git log --grep=TF-MAC-01 定位 |

两份签名归档保存在本地 .build/tiff-beta-20261121，上传日志保存在 local/tiff-beta-20261121。回退部署记录不会撤销 TestFlight 分发。
