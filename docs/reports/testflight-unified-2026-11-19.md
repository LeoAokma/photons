# Photons Studio 双平台 beta · 2026-11-19

| 编号 | 范围 | 依赖 |
| --- | --- | --- |
| TF-UNIFIED-01 | iPad 主记录构建使用 `com.leoaokma.photons` 和 Photons Studio 显示名称 | fork main `9fbb6f8` |
| TF-UNIFIED-02 | 编译 Mac 和 iPad Release、验证两份镜头配置 | TF-UNIFIED-01 |
| TF-UNIFIED-03 | 在 Apple ID 6835570029 添加 iOS，上传 iPad build 并提交 Private Beta 审核 | TF-UNIFIED-02 |

## TF-UNIFIED-01

在原有 iPad scheme 的构建命令中加入 `-xcconfig Apps/iPad/Studio.xcconfig` 来选择统一记录。该配置使用应用目标专用变量，使 SwiftPM 资源包沿用各自的标识。两个构建渠道使用各自的应用显示名提示导出位置。省略该配置时保留独立 Preview 的构建标识。应用数据仍位于各自的 iPad 沙盒。

使用 iPad Pro 13 英寸模拟器验证主记录构建。Info.plist 的标识和显示名分别为 `com.leoaokma.photons` 和 Photons Studio。两项定向测试均通过，涵盖两个镜头的实测端位、45/6 组标定数据及双击缩放。另用 Xcode 的 Release build settings 核对原 Preview 默认配置。

## TF-UNIFIED-02

源码 `5049d1b`。两端使用 0.3.0 (7)、Photons Studio、`com.leoaokma.photons`；版本与现有 Mac beta 的 0.3.0 对齐。Mac 经 `swift build -c release` 构建，用仓库的 `testflight.prepare` 在独立目录组装本地沙盒应用。沙盒检测和全景 worker 均通过。iPad 用 Studio.xcconfig 和匹配标识的 Apple Distribution 证书归档，设备族仅 iPad，最低 iPadOS 18，描述文件不含测试设备或调试权限。未附带测试原片。两端严格签名校验及二进制与 dSYM UUID 核对均通过。Mac 本地产物使用临时签名，iPad 归档使用分发签名。

两份配置在源码、Mac 包和 iPad 归档中的 SHA-256 均逐一相同。

| 镜头 | SHA-256 |
| --- | --- |
| APO-Digitar 43XL + iiic | `d25fa4a33a1fc7fbd45849b29799362535b7abf80b3e1279411861dac509cd41` |
| APO-Digitar 80N | `b99a41830f51423cde2fff5409c83b1e42bd3a1e6c2b488c76f7593ce344de27` |

本地构建在 `.build/unified-testflight-20261119/`，验证结果在 `local/unified-beta-20261119/release-verified.json`。这一步不涉及 TestFlight 分发或实机验证。
