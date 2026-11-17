# iPad 网格触摸与检查栏布局

日期：2026-11-17。分支：`codex/ipad-grid-interaction`，基线：`d39ccbd`。
保留原有导出尺寸修复及其他分支。按用户要求仅本地提交，不推送、不创建 PR、不更新 TestFlight。

| 追踪编号 | 独立验收目标 | 依赖 |
| --- | --- | --- |
| IPAD-GRID-01 (`51b5e03`) | 单击立即执行；双击打开、长按多选和拖动仍正确 | 现有 iPad 浏览及多选逻辑 |
| IPAD-GRID-02（包含本节的提交） | 选中/取消选中不改变网格几何，手动收放检查栏时卡片宽度固定 | IPAD-GRID-01 |

## IPAD-GRID-01 — `51b5e03`，单击不再等待双击失败

原浏览手势是长按与双击/单击的嵌套互斥识别。即使状态更新本身是同步的，
单击仍须等待双击识别失败才能触发，用户因此感觉点完很久才出现高亮。
此前的多选修复只替换了多选模式下的手势，未覆盖普通浏览模式。

新实现使用每次抬手都完成的 UIKit 单击识别器，并读取系统提供的 `UITouch.tapCount`。
第一次点击立即选择/取消选择；同一照片的第二次点击才进入大图。
跨照片的连续点击不会误触发打开，多选模式每次点击都独立切换勾选。
拖动、取消触摸和多指竞争继续由 UIKit 处理，不新增透明视图遮挡滚动或缩放。
长按独立进入多选，并排除该次长按松手后的额外单击，避免刚选中又被取消。
VoiceOver 的选择及打开动作继续保留。

窄屏改为通过现有检查栏工具栏按钮打开详情。单击只更新选择，以免立即弹出的模态窗口
截获第二次触摸，导致双击无法打开照片。关闭详情仍会清除普通浏览模式的选择。

文件：`MobileGridTap.swift`、`MobileWorkspaceView.swift`、iPad 引擎及 UI 测试。
参考 Apple 官方接口说明：[UITouch.tapCount](https://developer.apple.com/documentation/uikit/uitouch/tapcount)、
[UIGestureRecognizerRepresentable](https://developer.apple.com/documentation/swiftui/uigesturerecognizerrepresentable)。
目标最低 iOS 18，符合现有项目的系统要求。

本次验证（iOS 27.2，依赖使用锁文件；模拟器 `CODE_SIGNING_ALLOWED=NO`）：

- iPad Pro 13-inch (M5)：2 项引擎测试、4 项 UI 测试通过，0 跳过。
  覆盖首次点击、同图双击、跨图连点、选择模式连续勾选/取消、不重载编辑器，
  以及真实触摸的长按、多选双击、拖动不误选、取消选择、大图左右翻页。
- iPad mini (A20 Pro) 竖屏：`testCompactGridFirstTapKeepsGridAndDoubleTapOpens` 通过，
  确认首次点击不打开模态窗口、再次单击取消、双击进入大图、工具栏打开详情及关闭后清除选择。
- 初次 UI 验证发现长按松手后的单击冲突，排除长按释放事件后重新运行，以上最终测试全部通过。
- `git diff --check` 通过。结果位于忽略目录 `local/validation/grid-taps-2.xcresult`、
  `grid-taps-compact.xcresult` 及对应日志。

这是触摸行为回归验证，不是物理设备的显示帧延迟基准；未宣称具体毫秒响应目标。
该项不修改目录、原图、编辑记录、HDR 或渲染算法，可独立回退。

## IPAD-GRID-02 — 选择不再挤压网格

原来 `inspectorVisible` 随每次选中/取消选中变化，条件插入的 310pt 检查栏直接压缩 `LazyVGrid`。
网格使用只有最小宽度限制的自适应列，列数和卡片宽度会一起重算，导致照片占位框突然变形及换行。

宽屏现在从一开始就保留检查栏空间：无选择时显示现有的选择照片提示，选中时显示照片工具。
重复单击只清除选择，不移走检查栏。如果用户手动收起侧栏，后续选图尊重这一选择，
不会强制重新打开；可用工具栏再次展开。窄屏仍使用 IPAD-GRID-01 的显式详情弹窗。

卡片和自适应列使用相同的固定宽度。手动收放检查栏时允许列数变化，
但不会把照片占位框拉宽或压窄；捏合缩略图仍可主动调整大小。
手动收放使用 0.18 秒过渡；系统开启“减少动态效果”时不使用该动画。
选择本身不驱动此布局动画。

范围：`MobileWorkspaceView.swift` 及 UI 回归测试。依赖前项交互语义，不改变照片或数据库。

本次验证：

- iPad Pro 13-inch (M5)，iOS 27.2：5 项 UI 测试通过，0 跳过。
  新增 `testGridSelectionKeepsCardFramesAndHonorsCollapsedInspector` 逐张对比卡片的 x/y/宽/高，
  选中、切换及取消均保持不变；手动收起释放超过 250pt 网格空间而卡片宽高不变，
  收起后再选图不会展开侧栏，手动展开后几何恢复；捏合能主动改变卡片大小。
  另外验证双击/翻页、多选、取消选中，以及网格捏合 → 拼接 → 导出 → 返回的完整流程。
- iPad mini (A20 Pro) 竖屏：窄屏单击、双击及详情弹窗回归通过，0 跳过。
  首次运行中测试连续调用两次 `tap()` 被系统识别为双击，正确进入了大图；
  为“两个独立单击”的测试补充 0.7 秒间隔后通过。生产代码仍使用系统双击判定，未增加点击等待。
- 已检查保留的布局截图：高亮、直方图和检查栏显示正常，无重叠；使用生成样本，无用户照片。
- `git diff --check` 通过，依赖锁文件无变化。

结果位于忽略目录：`local/validation/grid-layout.xcresult`、`grid-layout-compact-2.xcresult`、
对应日志与 `grid-layout-attachments/` 截图。

此项未修改渲染、缓存或编辑数据。系统减少动态效果通过环境值控制动画，未自动化修改系统设置验证。
没有物理设备或 TestFlight 验证；可独立回退本项以恢复旧侧栏布局，保留 IPAD-GRID-01 的手势修复。

## 提交与发布状态

通过 `git log --all --grep=IPAD-GRID-` 可定位两项独立提交及各自完整说明。
基于当前本地开发链继续工作，没有向待合并 PR 增加提交，也没有创建新 PR。
