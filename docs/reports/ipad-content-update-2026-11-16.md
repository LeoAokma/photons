# iPad 内容更新：逐项追踪

一个主题 PR，各独立验收项分别 commit。基线为 `1db8fe3`；应用基线等同 PR 2 的 `a5cf5eb`，PR 2 当前未合并。本分支保留原有分支，不改写已发布历史。

| 编号 | 独立验收项 | 依赖 |
|---|---|---|
| IPAD-01 | Close 清理临时全景、恢复进入前视图，导出继续完成 | 基线 |
| IPAD-02 | 网格关闭所选照片侧栏时取消选中 | 基线 |
| IPAD-03 | 网格双击进入大图、大图左右翻页 | IPAD-02 |
| IPAD-04 | Fit/指定倍率双击切换、50/100/200/自定义、局部像素渲染 | IPAD-03 |
| IPAD-05 | 单图片库中的文件夹管理与筛选 | IPAD-03 |
| IPAD-06 | 对齐 Mac 信息结构的直方图 | 基线 |
| IPAD-07 | 有界、可复用的 HDR/SDR 预览缓存 | IPAD-04 |
| IPAD-08 | 设置中的缓存大小与清理 | IPAD-07 |
| IPAD-09 | 综合验证、PR 更新日志、iPad Developer Beta build 3 | 以上各项 |

## IPAD-01

- 原问题：临时拼接 plan/frame 在 Close 后留在主大图，直到选中另一照片。
- 变更：显式记录进入全景前的网格/大图状态；退出清空 plan/manifest/临时预览、使待完成预览失效，恢复原照片。导出先捕获 plan，退出不会取消已确认的导出。对齐任务取消后不再回填预览。
- 文件：MobileWorkspaceModel.swift、MobileWorkspaceView.swift、MobilePanoramaWorkspace.swift、IPadEngineTests.swift。
- 验证：iPad Pro 13-inch (M5) 模拟器 `testClosingPanoramaDiscardsTransientPreviewAndRestoresView` 通过，1 项 / 0 失败；日志 `local/build-logs/ipad-content-update/01-close.log`。
- 限制：物理设备 HDR/内存待 beta 验证；回退需同时回退视图与模型生命周期入口。
- Commit：以 `IPAD-01` 查询提交标题；无移植代码。

## IPAD-02

- 原问题：再次单击当前照片会关闭侧栏，但勾选与橙色高亮残留。
- 变更：单击当前照片、关闭网格侧栏或收起窄屏信息面板时清空单选；取消过期选中/渲染任务，避免错误照片回填。多选模式不受侧栏开关影响。缩略图增加明确的无障碍选中状态。
- 文件：MobileWorkspaceModel.swift、MobileWorkspaceView.swift、IPadUITests.swift。
- 验证：`testGridInspectorToggleDeselectsPhoto` 模拟器 UI 测试通过，1 项 / 0 失败，覆盖两次单击、重新选中及侧栏按钮关闭；日志 `02-selection.log`。
- 依赖：基线；提交标题含 `IPAD-02`，无移植。限制：窄屏分支已编译，完整横竖屏手动检查留待最终验收；回退模型方法与调用方一起回退。

## IPAD-03

- 变更：网格双击直接打开大图；单击和长按仍分别负责信息/多选。Fit 下左右滑动按当前搜索结果翻页，首尾停止，不循环；放大后的拖动留给平移。大图另有上一张/下一张按钮与文件名。
- 文件：MobileWorkspaceView.swift、MobileWorkspaceModel.swift、IPadUITests.swift。
- 验证：`testDoubleTapOpensPhotoAndSwipesNavigate`、`testGridInspectorToggleDeselectsPhoto` 通过，2 项 / 0 失败；日志 `03-navigation.log`。初次边界断言受到旧样例导出污染，测试现以 `--demo --reset-demo` 重置专用 Generated Samples 库；正常用户库不受影响。单击断言等待系统双击识别窗口结束。
- 依赖：IPAD-02 (`1ad56ac`)；提交标题含 `IPAD-03`。限制：缩放导航规则将在 IPAD-04 延续；物理触屏最终体验由 beta 验证。无移植，回退需同步恢复手势与 UI 测试。
