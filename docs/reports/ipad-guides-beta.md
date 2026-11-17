# iPad 引导教程与 Beta 更新

日期：2026-11-17。基线 `ccc3978`，开发分支 `codex/ipad-guides-beta`。
用户授权合并此前尚未提交 PR 的修复，并发布到现有 Developer Beta / Private Beta。
用户已选择：PR 在 `LeoAokma/photons` fork 中以 `codex/ipad-content-update`（上游 PR #3）为基线。
不改写或删除既有分支，不重复包含 #2/#3 的已提交功能，不合并待审 PR。

| 编号 | 独立目标 | 依赖 |
| --- | --- | --- |
| IPAD-GUIDE-01 | Alignment options 始终展开 | 既有拼接窗口 |
| IPAD-GUIDE-02 | 主界面网格/单张模式的 💡 红框引导，中英文 | 共用引导组件 |
| IPAD-GUIDE-03 | 拼接窗口 💡 引导，包含各侧栏模块、拖拽与自动/手动解算 | 01、02 |
| IPAD-GUIDE-04 | 每个应用 build 首次启动的快速教程与完成记录 | 02 |
| IPAD-GUIDE-RELEASE | 汇总 PR、0.1.0 (5) 签名构建和 DB/PB 分发 | 所有功能验证完成 |

## IPAD-GUIDE-01

将拼接设置中的 `DisclosureGroup` 换成带标题的普通垂直内容组，传感器尺寸、曝光匹配、
运动主体处理和接缝柔化选项不再需要展开操作。保留既有选项值、计算逻辑和滚动行为。
文件：`Sources/PhotonsMobile/MobilePanoramaWorkspace.swift`。

本次验证：iOS 27.2 / iPad Pro 13-inch (M5)，
`testGridInspectorSelectionAndPanoramaWorkflow` 通过（0 跳过），涵盖拼接、位置修改、LCC、导出与返回。
`git diff --check` 通过。日志和 xcresult 位于忽略目录 `local/validation/guide-01.*`。
此项无新增计算逻辑，可独立回退；尚未通过物理 iPad 验证。

## 发布基线核对

内置浏览器确认 App Store Connect 的 build 4 与 build 1 均在 DB/PB Testing；build 2/3 已过期。
拟上传 build 5，不修改既有 tester 列表、公开链接或旧 build 状态。后续以服务器实际处理/审核状态为准。
