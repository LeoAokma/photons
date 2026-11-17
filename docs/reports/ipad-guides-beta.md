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

## IPAD-GUIDE-02

新增共用引导组件 `MobileGuide.swift`。通过实际控件几何定位红框，保留高亮区域亮度，
说明卡优先放在不遮挡目标的位置；下一步/上一步与右下角 Close 始终可用。
引导拦截背景操作，关闭后保留原选择、视图及编辑状态。底部预留教程操作区，以免盖住真实导出按钮。

主界面在导入左侧加入圆形 💡。网格教程包含单击、双击、长按多选、捏合和所有顶部工具；
单张教程另含 Fit 状态滑动翻页、放大后拖动、倍率及翻页按钮。
条件性出现的拼接按钮在尚未多选时用工具栏作定位，并明确说明至少选择两张照片。
新增 34 项语义清晰的中英文键，不迁移旧翻译架构。

本次验证：iPad Pro 13-inch (M5) / iOS 27.2，1 项引擎几何/回退/导航/关闭测试及
1 项真实 UI 引导流程通过，0 跳过；覆盖全部主工具栏说明、红框存在、Close 位置、
关闭不改变选择以及单张滑动/倍率提示。截图人工检查通过。后续仅润色导出说明文字。
日志与结果：`local/validation/guide-02.*`，截图 `guide-02-review.png`（忽略目录，生成样本）。
`git diff --check` 通过。未改变图像处理或图库数据；物理设备及 VoiceOver 人工操作尚未验证。
此项为 03/04 提供共用引导组件，回退时需连同依赖项处理。
