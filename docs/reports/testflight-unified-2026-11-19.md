# Photons Studio 双平台 beta · 2026-11-19

| 编号 | 范围 | 依赖 |
| --- | --- | --- |
| TF-UNIFIED-01 | iPad 主记录构建使用 `com.leoaokma.photons` 和 Photons Studio 显示名称 | fork main `9fbb6f8` |
| TF-UNIFIED-02 | 编译 Mac 和 iPad Release、验证两份镜头配置 | TF-UNIFIED-01 |
| TF-UNIFIED-03 | 在 Apple ID 6835570029 添加 iOS，上传 iPad build 并提交 Private Beta 审核 | TF-UNIFIED-02 |

## TF-UNIFIED-01

在原有 iPad scheme 的构建命令中加入 `-xcconfig Apps/iPad/Studio.xcconfig` 来选择统一记录。该配置使用应用目标专用变量，使 SwiftPM 资源包沿用各自的标识。两个构建渠道使用各自的应用显示名提示导出位置。省略该配置时保留独立 Preview 的构建标识。应用数据仍位于各自的 iPad 沙盒。

使用 iPad Pro 13 英寸模拟器验证主记录构建。Info.plist 的标识和显示名分别为 `com.leoaokma.photons` 和 Photons Studio。两项定向测试均通过，涵盖两个镜头的实测端位、45/6 组标定数据及双击缩放。另用 Xcode 的 Release build settings 核对原 Preview 默认配置。
