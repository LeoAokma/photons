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

## IPAD-04

- 变更：大图右上角显示当前倍率、Fit 和双击目标；50/100/200% 及 10–800% 自定义倍率持久保存。双击在 Fit 与目标间切换，手势缩放/平移保留；100% 按图像像素对屏幕物理像素计算。缩放或平移结束后的可见区域以 180 ms 去抖请求实际像素，不再只拉伸 Fit 预览。
- 渲染：使用共享 RenderGraph 的 outputWindow，包含编辑后裁剪/旋转坐标，额外 64 px 邻域支持防止窗口边界影响锐化；全景/LCC 使用共享线性 composite 的可见区域。旧请求在切图、编辑、HDR 切换、退出全景及内存警告后失效。空间不足保留预览并给出提示，不虚称已有完整细节。
- 文件：新增 MobilePhotoCanvas.swift；MobileEngine/WorkspaceModel/WorkspaceView/PanoramaWorkspace，engine/UI 测试。
- 验证：`testZoomDetailMatchesEditedFullResolutionPixels` 通过，比较裁剪、旋转、曝光后的局部和完整渲染；最初无邻域余量时边缘差异暴露了锐化边界问题，修复后通过。模拟器内存预算使用物理内存的受限比例，实体机使用可用进程内存。
- UI 验证：`testDoubleTapTogglesFitAndSelectedMagnification` 最终通过，覆盖 Fit↔200%、Fit↔50%、自定义150%和 Fit 按钮；自定义输入改为带固定顶部操作栏的 sheet，避免键盘遮住确认按钮。导航在新视口实现上已通过。日志 `04-zoom.log`、`04-zoom-ui.log`。
- 依赖：IPAD-03 (`e886f58`)。提交标题含 IPAD-04。限制：原始文件解码仍可能需要整幅源图；局部输出避免整幅后处理/显示缓冲，但不声称 RAW 解码完全分块。全景多源高倍率受内存预算限制。无移植；回退需同步回退新视口、引擎区域入口和模型请求失效逻辑。

## 补充需求

- IPAD-10：iPad 简体中文界面，独立 commit，与其余功能同一 PR/build。
- IPAD-11：Lens profiles 详情（相机/光圈/标定机身/备注、方向与覆盖范围、各标定帧参数），独立 commit，与其余功能同一 PR/build。
- IPAD-09 的最终交付还依赖 IPAD-10、IPAD-11。

## IPAD-05

- 变更：固定单一 iPad 图片库，明确拒绝把另一 `.photonslibrary` 当照片导入。库内增加 All photographs / Unfiled / 自建文件夹、计数、创建/重命名/移除、移动选中照片及当前文件夹导入。大图翻页使用当前文件夹与搜索结果。
- 数据：文件夹是库内的归类目录，一张照片最多属于一个文件夹；索引原子保存在该库的 MobileFolders.json。整理文件夹不搬动或复制原片，移除文件夹只使成员返回 Unfiled，保留编辑历史。已有图库自动以未归类方式兼容，不创建第二用户库。
- 文件：MobileLibraryFolders.swift、MobileEngine/WorkspaceModel/WorkspaceView、engine/UI 测试。
- 验证：`testSingleLibraryFoldersPersistWithoutChangingOriginalsOrEdits` 和 `testFoldersFilterMoveAndPersist` 通过，2 项 / 0 失败；验证重开持久化、原片字节/编辑不变、名称冲突、跨库导入拒绝、UI 创建/移动/筛选。日志 `05-folders.log`。
- 依赖：IPAD-03；提交标题含 IPAD-05。限制：本轮为库内单层归类，不把 Files 中的物理文件夹变成第二库；移除文件夹有明确保留照片的确认。无移植。回退代码不会删除索引或原片。

## IPAD-06

- 变更：侧栏直方图增加 HDR/SDR 与色域、输出尺寸、0–255 代码坐标、HDR +1…+4 EV 轴、当前显示上限、过白/削顶/削底、采样数和触摸代码/档位/RGB bin 读数。采用 Mac 的 SDR/HDR 各半宽、线性高度、排除端点尖峰的每通道归一化与 RGB 加色叠加；无额外白色曲线。
- 文件：新增 MobileHistogram.swift，Inspector 调整，engine/UI 验证。
- 来源：参考当前基线的 Sources/PhotonsUI/HistogramPlot.swift、HistogramCard.swift；测量仍来自共享 Histogram/HistogramSnapshot。未改 Mac 行为。
- 验证：`testHistogramAxisAndDisplayClippingMatchMacSemantics`、`testHistogramShowsClippingAndTouchReadout` 通过，2 项 / 0 失败；显示上限改变不改变 bins，触摸读数和统计行可见。日志 `06-histogram.log`，UI 测试保留截图。
- 依赖：共享直方图基线；提交标题含 IPAD-06。限制：触摸直方图显示 bin 计数，不是照片上触点的逐像素 RGB；真实 HDR 显示仍需设备验证。回退新视图和 Inspector 调用即可。

## IPAD-07

- 变更：一次场景线性渲染生成 HDR/SDR 配对预览与直方图；切换模式复用大图、缩略图、局部细节和全景预览。全景切换不再调用调色/重新合成入口。照片预览持久化为半浮点 LZFSE 无损配对记录，重启可复用，损坏记录自动重新生成。
- 预算：大图 96 MiB、缩略图 16 MiB、局部细节 48 MiB 独立 LRU；磁盘预览最多 512 MiB。缓存键包含源文件路径/大小/修改时间、编辑参数、尺寸和视口；磁盘解压使用固定尺寸缓冲，避免无界解压。收到内存警告释放工作缓存。
- 文件：MobilePreviewCache.swift、MobileEngine.swift、MobileWorkspaceModel.swift、IPadEngineTests.swift。依赖 IPAD-04；无移植代码。
- 验证：HDR 高光/持久化、局部像素一致性、全景切换复用均通过；配对缓存测试覆盖切换与缩略图隔离、重启零渲染、编辑/源文件失效、局部复用、LRU 和损坏回退。初次测试发现 URL 元数据缓存使修改时间失效未触发，改为实时文件属性后重测通过。日志 `07-cache.log`、`07-cache-recheck.log`；4 个测试最终通过。
- 限制：为首次渲染增加一次轻量显示投影，以换取首个 HDR/SDR 切换也无需重跑开发流程；尚未测实体机耗电。内存预算指引擎预览缓存，不包含解码器、UI 当前图像和系统 GPU。提交标题含 IPAD-07；IPAD-08 依赖此缓存目录/结构。

## IPAD-08

- 变更：General / Photo library 设置显示预览磁盘大小、文件数、引擎预览内存，提供刷新和带确认的清理。清理先使待完成预览失效，等待当前照片的编辑加载完成，再删除 MobilePreviews 并释放引擎工作缓存；屏幕正在显示的图像保留，下次按需重建。
- 文件：MobileCacheSettings.swift、MobileTools.swift、MobileEngine.swift、MobileWorkspaceModel.swift、engine/UI tests。依赖 IPAD-07 (`461f7d5`)；无移植代码。
- 验证：`testClearCacheKeepsLibraryOriginalsEditsFoldersAndProfiles`、`testSettingsMeasuresAndClearsPreviewCache` 最终通过（2 项 / 0 失败），覆盖清理后磁盘/内存归零、照片字节/编辑/归类/配置/导出保留、再次请求重建，以及 UI 确认/计数/返回网格。早期 UI 断言受系统重复按钮节点与组合内容可访问性影响，修正定位并提供明确文件数无障碍值后通过。最终日志 `08-cache-settings-final.log`。
- 限制：内存行统计引擎预览缓存，并非整个应用占用；确认说明原片和编辑不被删除。回退时同步回退 UI/模型/引擎入口，磁盘缓存可由 IPAD-07 继续使用。提交标题含 IPAD-08。

## IPAD-11

- 变更：Lens profiles 列表可进入完整详情，显示相机、光圈、标定机身、创建日期、格式版本、标定帧数、备注、共享配置。按方向展示 Mac 同规则的测量覆盖矩形/中心点和 X/Y 移轴范围；展开帧可查看文件名、位置、传感器/像素尺寸、ISO、曝光时间、拍摄日期、机身方向、测量与渲染网格尺寸/通道/空间。
- 文件：MobileProfileDetails.swift、MobileTools.swift、MobileEngine.swift、engine/UI tests。来源：参考当前 Mac LCCProfileLibraryView 覆盖图与说明，复用共享 LCCProfileStore/Codec/校验；不修改配置原始数据。
- 验证：`testLensProfileDetailsPreserveCaptureMetadataAndCoverage`、`testLensProfileOpensMetadataCoverageAndCaptureDetails` 均通过（2 项 / 0 失败），内置配置的元数据/覆盖区域校验、设置进入详情和展开帧。日志 `11-lens-details.log`，UI 保留详情截图。
- 限制：仅显示文件实际包含的可选元数据，缺失机身显示 Not recorded；不同配置的备注/文件名作为用户数据不自动翻译。无新增依赖；IPAD-10 将翻译新增界面。提交标题含 IPAD-11；回退视图与导航入口一起进行。
