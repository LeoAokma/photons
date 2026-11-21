# 预览生成与全景拼接算法审计

基线为 fork main 的 `a20dd64`。各项可以独立验收与回退。用 `git log --oneline --grep=<追踪编号>` 可定位各项实现。测试数据来自仓库夹具和生成的场景。以下时间在 Apple M5 Pro、Swift 6.4.2 上测得。

| 追踪编号 | 验收目标 | 依赖 |
| --- | --- | --- |
| PREVIEW-FIFO-01 | 降低 Mac 预览内存索引淘汰成本，保留覆盖、淘汰和清空语义 | 无 |
| PANO-VOTE-01 | 降低平移配准的位移投票成本，保留入选匹配点及其顺序 | 无 |
| PANO-EXPOSURE-01 | 在关闭曝光匹配时省去增益求解，保留接缝与输出像素 | 无 |
| MAC-ARROW-NAV-01 | 在 Mac 各照片浏览模式及大图放大时用左右键切图 | 无 |

## 审计范围

- Mac 的初始预览和直方图回填按照片逐项推进。生成缩略图还涉及 RAW 解码、缩放、编码和磁盘缓存。直方图对采样像素作线性遍历。单独测量索引的结果不能推算整库的生成耗时。
- `ThumbnailService.takeNextLocked` 每次出队都扫描候选项，连续排空 Q 个同时待办任务最坏需 O(Q²)。后台逐张预热与突发滚动产生的队列深度不同。若替换队列，应先覆盖优先级提升、合并请求、暂停及取消。HD 文件写入时还会枚举所在分片，成本随该分片内文件数增加。
- iPad 的 `MobileWorkspaceModel.warmThumbnails` 每选下一张预览都从照片列表头部查找。生成 V 张可见缩略图最多检查 O(NV) 个条目，N 为图库照片数。可见项为空时还会生成当前目录的过滤结果再取前 12 项。进一步验证需要覆盖滚动、换目录及异步请求返回时可见范围已变的情况。
- 全景分析在符合条件的照片对之间计算特征。平移路径重复提取同一帧的角点，描述子最近邻仍需比较两帧的特征。接缝准备还会在曝光求解中重复采样相同的图像对。多图、低重叠和运动场景适合用于评估这些阶段。接缝掩膜的方框模糊已经使用滑动和。

## PREVIEW-FIFO-01 · Mac 预览

旧实现对编辑参数、源图长边和显示尺寸分别维护字典与键数组。索引已满时，插入新键需要搬移其余 K−1 个键。候选实现将键保存在环形数组中，在原有锁内更新字典和环的头部。容量仍为 4,096，覆盖已有键保留最初的 FIFO 顺序。单次满容量淘汰从 O(K) 降到平均 O(1)，内存保持 O(K)。涉及 `ThumbnailProvider`、`PreviewFIFOIndex` 和对应单元测试。

先独立编译候选实现（`xcrun swiftc -O -whole-module-optimization`），与旧数组算法对照 120,000 次操作，覆盖六种容量、覆盖、淘汰后重新插入和重置。各次读回及定期全表比对一致，然后接入生产路径。

| 满容量附近的负载，每轮 100,000 次写后读取 | 原实现中位数 | 候选中位数 |
| --- | ---: | ---: |
| 不断插入新键，K=64 | 20.73 ms | 16.50 ms |
| 不断插入新键，K=1,024 | 33.97 ms | 17.52 ms |
| 不断插入新键，K=4,096 | 70.96 ms | 17.79 ms |
| 重复写入驻留键，K=4,096 | 7.61 ms | 5.68 ms |

每组新旧交替测七轮，使用相同键与校验和。独立实验保存在本机 `local/out/preview-stitch-audit-a20dd64/preview`。

集成验证使用 `PHOTONS_LANGUAGE=zh-Hans PHOTONS_TEST_RAW="$PWD/Tests/Fixtures/hdr-bracket-b.dng" swift test --filter 'PreviewFIFOIndexTests|PreviewCacheManagementTests|ThumbnailHDRCacheTests|ThumbnailRefreshTests|ThumbnailServiceTests'`。本次 52 个测试全部通过，无跳过。另用较暗的 bracket-a 运行 HDR 测试，有两例达不到要求的高光阈值。在基线的 ThumbnailProvider 上重跑这两例，三项读数完全相同（0.7783203125、1.0、0.74951171875）。采用明亮的 bracket-b 时，14 个 HDR 测试全部通过。


## PANO-VOTE-01 · 平移配准

改动位于 `TranslationRegistration.align` 的无先验位移路径，输入是整数角点的位移。旧实现以每个匹配为中心，重新过滤全部 M 个匹配，分配临时数组并逐点求距离，时间 O(M²)。按 y 行分组、按 x 排序后，可在相邻七行各用一对单向指针计数。开圆盘半径仍为 4，行间距 0 到 2 时横向允许 3 像素，行间距 3 时允许 2 像素。排序使最坏时间为 O(M log M)（按通常字典查找成本），其余扫描为 O(M)，空间 O(M)。最后按原输入顺序解决票数并列、提取内点。最少五点、锚点抽样及后续亚像素拟合沿用原规则。

先在独立可执行程序中并排编译完整的新旧平移实现。第一种候选按每个唯一位移查哈希邻域，64 个分散匹配时用了 60.4 µs，旧实现为 8.2 µs，因此舍弃。按行的候选在 1,410 组输入上与逐点参考返回完全相同的有序索引，涵盖负位移、重复、并列、边界和最多 900 点。9 对完整配准输入包含生成纹理、空白、不相关照片和从仓库 DNG 裁出的重叠视图，共 7 对通过、2 对拒绝。两套实现的结果逐一吻合，位移与评分的浮点位模式、内点数和锚点序列均相同。

| 输入 | 匹配数 | 参考投票 | 按行投票 |
| --- | ---: | ---: | ---: |
| DNG 重叠裁片 | 198 | 129.16 µs | 4.44 µs |
| 分散匹配 | 16 | 0.80 µs | 1.99 µs |
| 分散匹配 | 64 | 8.26 µs | 7.56 µs |
| 分散匹配 | 900 | 1,196.14 µs | 107.18 µs |
| 集中匹配混入离群点 | 900 | 2,411.28 µs | 44.90 µs |

使用 `xcrun swiftc -O -whole-module-optimization`，七轮交替测量取中位数。投票对照中参考实现按原距离规则返回索引。整对图像的对照直接调用原版及候选版的完整配准函数。同一 DNG 的两块 256×200 裁片，整对配准从 6.089 ms 到 5.954 ms；多数时间花在角点提取、描述子比较与亚像素拟合。16 个分散点时，按行分组的固定开销约多 1.2 µs。整套四张或更多 RAW 的拼接速度仍需单独测量。本机实验保存在 `local/out/preview-stitch-audit-a20dd64/pano`。

该项可用 `git log --oneline --grep=PANO-VOTE-01` 定位。前一项预览缓存提交为 `1d01581`，两者可以独立回退。回归测试 `TranslationConsensusTests` 将生产函数与逐点投票逐项比较。

本次 `PHOTONS_LANGUAGE=zh-Hans swift test --filter 'PhotonsPanoramaTests|PanoramaJobTests'` 共 77 项，67 项通过，10 项因外部 RAW、预生成全景或可选校准生成条件未提供而跳过，零失败。在 iPad Pro 13 英寸模拟器运行 `IPadEngineTests/testPanoramaAlignmentScaledLosslessExportAndMetadata` 通过，覆盖三图配准、预览直方图、缩放与全尺寸导出以及元数据回读。未测旧款设备实机。


## PANO-EXPOSURE-01 · 关闭曝光匹配的接缝准备

`PanoramaSeams.prepare` 从已求解的帧向剩余帧搜索重叠最多的下一帧。此前，关闭曝光匹配时也先执行完整搜索，再丢弃结果，并逐像素乘以 1。在 N 张稠密重叠图中，旧循环的跨集合帧对数为 N(N²−1)/6，每对扫描约 S 个采样位置，另有部分中位数排序。关闭选项后直接建立 N 个单位增益，省去所有这些采样和乘法。接缝仍执行光栅化、归属计算及蒙版生成。默认开启曝光匹配时仍走原有求解路径。

隔离实验并排编译原版和候选版的完整接缝准备，使用独立编译的优化版 PhotonsPanorama 及本地 Release 依赖。八组输入包括 1、2、4、8、16 帧、完全不重叠、HDR、运动避让以及曝光匹配关闭和开启。每个输入都预置了旧增益，模拟在已有预览上切换选项。固定 Swift 哈希种子以便在相同条件下复现并列选择。逐一核对全局增益、归属标签、蒙版字节、光学位置、局部增益图、原生半浮点预览及完整合成的半浮点像素。连续八轮均一致。

早期一次使用 Debug 辅助库的实验，在将预览 CGImage 再经 Core Image 转换后发生字节比较差异，原因未重现。最终验证直接逐行读原生 CGImage 像素，排除行末填充，同时保留完整合成像素检查；再次做额外颜色转换的八轮对照也一致。

| 帧数，曝光匹配关闭 | 原接缝准备 | 候选接缝准备 |
| --- | ---: | ---: |
| 2 | 9.07 ms | 8.73 ms |
| 4 | 14.17 ms | 13.10 ms |
| 8 | 20.61 ms | 18.41 ms |
| 16 | 43.83 ms | 30.95 ms |

每张源图 140×92，具有曝光差异与纹理。新旧实现各预热一次，七轮交替测量取中位数，计时包含整个接缝准备。等价性验证另行比较输出。此测量针对关闭曝光匹配的选项，未计入完整 RAW 解码或文件导出。

集成后 Mac 的 `testDisablingExposureMatchingClearsPreviousGainsAndCanBeReversed` 从不同亮度的两图产生非单位增益，关闭后验证恢复单位增益及清除局部补偿，再开启后核对增益、接缝归属和蒙版。连同缩略图、配准、渲染和导出工作进程测试，一次执行 65 项，62 项通过，3 个外部 Boston 夹具测试跳过，零失败。本机原型和详细日志在 `local/out/preview-stitch-audit-a20dd64/exposure`。可独立回退；平移投票提交为 `fff6112`。本项的实现提交可用 `git log --oneline --grep=PANO-EXPOSURE-01` 定位。

iPad 模拟器执行 `testPanoramaAlignmentScaledLosslessExportAndMetadata` 和 `testPanoramaToneUpdatesPreviewHistogramAndExport` 均通过。最终 `swift build -c release` 成功。各项的耗时取自 M5 Pro；iPad 模拟器用于验证功能。旧 Mac、旧 iPad 及用户 502–505 原片组合未做实机性能测量。


## MAC-ARROW-NAV-01 · Mac 左右方向键切图

网格与胶片条已有方向键导航。左侧照片表格和单图画布拿到焦点时，左右键没有切图入口；双击从网格进入大图还会移除原先持有键盘焦点的网格视图。`EditorWindowController` 的主编辑窗口现在将普通左右键交给 `WorkspaceRootView`，后者在照片列表、大图及窗口本身持有焦点时，沿用 `CatalogSession.moveAnchor` 按当前排序和筛选结果移动。双击和工具栏切换视图时将照片焦点交给新画布，浏览区显示对应的当前缩略图。已有修饰键操作、文本光标、文件夹树和调节控件继续由各自的响应器处理。

本次 `PHOTONS_LANGUAGE=zh-Hans swift test --filter 'GridEditTargetTests|GridDoubleClickCentre391Tests|BrowserPaneDoubleClickTests|DoubleClickParity415Tests|ShiftRangeSelection375Tests|StackProjection378Tests|AdjustmentSlider'` 执行 43 项，全部通过。新增窗口测试通过 AppKit 的 `sendEvent` 发送左右键，核对网格、左侧照片列表、胶片条、进入大图后、画布双击放大后及从工具栏切换后的选中照片和浏览模式，并在文本框中核对光标移动。首张照片按左键会停留在首张。范围选择与折叠堆栈导航另由已有用例覆盖。

此项为独立的 Mac 交互改动；提交可由 `git log --oneline --grep=MAC-ARROW-NAV-01` 定位。前三项优化的实现提交分别为 `1d01581`、`fff6112`、`08c9297`。测试使用临时图库，未向 App Store 提交。

最终源代码在 Mac 使用 `swift build -c release` 构建成功；iPad 使用 Studio 配置、Release、`generic/platform=iOS` 和 `CODE_SIGNING_ALLOWED=NO` 为 arm64 设备目标构建成功。iPad 功能验证使用上述模拟器。
