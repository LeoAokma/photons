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
| IPAD-GUIDE-05 | 默认跟随设备语言，可在设置中切换，中英文提示同步 | 02/03/04 |
| IPAD-GUIDE-06 | 所有教程支持左右滑动翻页，保留按钮与 Close | 02/03/04/05 |
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

## IPAD-GUIDE-03

拼接窗口 HDR 旁加入圆形 💡，分步框出预览、直方图、HDR、侧栏、机身/方向、相对位置示意图、
照片列表与坐标、位置引导、对齐选项、重新对齐、LCC、曝光/高光和导出。
侧栏步骤自动滚动到对应模块。突出说明可拖动任何照片矩形（含中心帧），以及自动估算与
输入实测读数/拖动后开启引导并重新对齐的区别。透视模式使用独立布局与 LCC 说明。
新增 30 项中英文键。所有页面右下角提供 Close/关闭。

本次验证：13-inch (M5) 上的移轴全教程和主界面教程回归共 2 项 UI 测试通过；
iPad mini (A20 Pro) 竖屏中文透视教程 1 项 UI 测试通过，均为 iOS 27.2，0 跳过。
检查 HDR 红框与真实工具栏按钮坐标一致，关闭引导不改变导出可用状态；导出红框不被教程 Close 遮挡。
首次测试发现 NavigationStack 不完全遵循外层 safeAreaInset，改用实际内容底部留白后复测通过。
英文移轴示意图及中文竖屏导出截图均已检查。64 项 guide 键中英文一致且非空。
日志/结果/截图：忽略目录 `local/validation/guide-03-wide-2.*`、`guide-03-compact.*`。

范围：MobilePanoramaWorkspace、MobileGuide、翻译及 UI 测试。教程只滚动控件，不修改参数、布局解算或图像数据。
依赖 01/02；可单独回退拼接教程，但底部避让修复也服务于其他教程。物理设备尚未验证。

## IPAD-GUIDE-04

首次启动按 `CFBundleShortVersionString + CFBundleVersion` 判断当前 build，自动展示五步快速上手。
右下角 Close 记录该 build 已查看；同 build 重启不再自动弹出，新 build 会弹出，回到曾看过的旧 build 不重复。
记录属于应用偏好，不属于照片库；手动灯泡教程始终可重看。卸载后重新安装的偏好存储从空状态开始。
DEBUG UI 测试使用独立 suite 和模拟 build 标识，不影响真实使用记录；Release 不包含这些测试覆盖入口。

本次验证：iPad Pro 13-inch (M5) / iOS 27.2，1 项跨实例/跨 build 的持久化测试、
1 项真实启动→关闭→重启→手动重看→换 build 再启动的 UI 测试通过，0 跳过。
日志/结果：忽略目录 `local/validation/guide-04.*`。`git diff --check` 通过。
范围：MobileGuideHistory、主界面启动、10 项中英文键和测试；依赖 02 的共用组件。
回退不会删除照片或已保存偏好。测试使用 Debug 的 build 标识注入；最终 Release 将另行核验实际版本字段。

## IPAD-GUIDE-05

iPad 新安装默认跟随设备语言，按设备偏好顺序选择英文或简体中文；其他语言回退英文，中文变体使用现有简体中文。
设置提供“跟随系统 / English / 简体中文”，手动偏好优先且立即生效。已有明确语言偏好保留。
普通译文字符串显式观察 SwiftUI locale，以刷新教程、工具栏、表单和镜头详情，不重建照片模型或重置选择。
调节项标题按当前语言生成；检查器标签使用稳定键，切换语言不会跳到历史页。
补齐透视模式 LCC 说明的中文。Mac 保留原有重启后切换语言行为。

本次验证：语言优先级引擎测试、中文浏览/设置/镜头详情 UI 测试通过；
即时英文→中文→英文、检查器保持原页、曝光标题刷新、跟随设备中文启动首次教程的 UI 测试通过。
首次 UI 运行因测试预期标题少写“多选”而失败，修正断言后完整流程通过，未因此修改产品译文。
截图确认中文快速上手、红框和右下角关闭。74 项教程键中英文一致、非空。
Mac `swift test --disable-automatic-resolution --skip-update --filter DevelopTests` 构建通过，23 项测试通过。
证据：忽略目录 `guide-05.*`、`guide-05-live-2.*`、`guide-05-mac.log`、`guide-05-review.png`。
`git diff --check` 通过；无跳过，物理设备尚未验证。历史编辑记录及用户命名保持原内容，不当作界面文字重译。
范围：Localization、DevelopControls、Mobile 视图、翻译与测试；依赖 02/03/04。回退恢复原语言行为，不改变照片数据。

## IPAD-GUIDE-06

共用教程支持左滑下一页、右滑上一页，首次上手、网格、单张和拼接教程全部生效。
单次滑动最多翻一页，首尾不循环；小幅拖动与主要为纵向的滚动不翻页，长说明仍可上下阅读。
底部按钮及右下角 Close 保留，并增加中英文滑动提示。手势由教程遮罩接收，不传递到底层照片或拼接图。

本次验证：滑动方向/阈值/首尾/关闭边界引擎测试通过；四类教程真实触摸往返翻页、纵向不翻页、按钮保留、
关闭后照片仍为原图、未改变选择和拼接导出状态的 UI 测试通过，0 跳过。
测试初次英文预期标题写错，修正后又遇到 XCTest 对横屏右侧 ScrollView 可见范围的误判；
改用从实际控件位置取得的屏幕坐标拖动后全流程通过。已查看截图，确认卡片、滑动提示与 Close 正常显示。
证据：`local/validation/guide-06.*`、`guide-06-ui-3.*`、`guide-06-review.png`（均忽略）。
`git diff --check` 通过；物理设备/VoiceOver 手工操作未验证。此项依赖共用教程，可独立回退滑动行为。

## 新增功能 commit 索引

| 编号 | Commit | 行为 |
| --- | --- | --- |
| IPAD-GUIDE-01 | `108e72b` | 对齐选项始终展开 |
| IPAD-GUIDE-02 | `e3da364` | 主界面网格/单张红框教程 |
| IPAD-GUIDE-03 | `e77b65f` | 拼接各模块、拖动和解算教程 |
| IPAD-GUIDE-04 | `22db4c5` | 每个 build 首次快速上手 |
| IPAD-GUIDE-05 | `ed5147b` | 跟随设备语言及即时切换 |
| IPAD-GUIDE-06 | `e206f11` | 所有教程左右滑动翻页 |

最终集成验证和 DB/PB 发布记录见 [iPad Beta 5](ipad-beta-5-2026-11-17.md)。
