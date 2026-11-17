# iPad 网格触摸与检查栏布局

日期：2026-11-17。分支：`codex/ipad-grid-interaction`，基线：`d39ccbd`。
保留原有导出尺寸修复及其他分支。按用户要求仅本地提交，不推送、不创建 PR、不更新 TestFlight。

| 追踪编号 | 独立验收目标 | 依赖 |
| --- | --- | --- |
| IPAD-GRID-01 | 单击立即执行；双击打开、长按多选和拖动仍正确 | 现有 iPad 浏览及多选逻辑 |
| IPAD-GRID-02 | 选中/取消选中不改变网格几何，手动收放检查栏时卡片宽度固定 | IPAD-GRID-01 |

## IPAD-GRID-01 — 单击不再等待双击失败

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

## IPAD-GRID-02 — 待实现

计划：宽屏默认固定检查栏，普通选中/取消选中只更新其内容；手动收起才调整网格可用空间。
卡片改为固定宽度，避免侧栏操作造成占位框横向拉伸；保留用户捏合调整缩略图大小的操作。
为手动收放提供短过渡，并尊重系统“减少动态效果”设置。
