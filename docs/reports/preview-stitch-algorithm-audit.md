# 预览生成与全景拼接算法审计

基线为 fork main 的 `a20dd64`。两项可以独立验收与回退。用 `git log --oneline --grep=<追踪编号>` 可定位各项实现。测试数据来自仓库夹具和生成的场景。以下时间在 Apple M5 Pro、Swift 6.4.2 上测得。

| 追踪编号 | 验收目标 | 依赖 |
| --- | --- | --- |
| PREVIEW-FIFO-01 | 降低 Mac 预览内存索引淘汰成本，保留覆盖、淘汰和清空语义 | 无 |
| PANO-VOTE-01 | 降低平移配准的位移投票成本，保留入选匹配点及其顺序 | 无 |

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
