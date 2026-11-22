# 0.3.5 接片默认设置与天空树缘

| 编号 | 验收项 | 依赖 |
| --- | --- | --- |
| PANO-DEFAULT | Mac、iPad 新接片的防伪影默认关闭，原有任务保留开关 | 无 |
| LCC-SKY | 定位并验证 496–501、504–505 在预览和导出中的青色断层 | 用 PANO-DEFAULT 的新接片设置复现 |
| LCC-SKY-VERIFY | 全尺寸成品回读、两端构建和回归验收记录 | LCC-SKY |

## PANO-DEFAULT · 6fcef559

Mac 和 iPad 都通过 PanoramaOptions 初始化接片。修改此处的默认值后，新建接片的防伪影开关为关。已有快照和清单继续读取各自保存的布尔值。防伪影可在原位开关，沿用同一组配准位置。没有改动接缝计算。

Mac 验证覆盖合成运动物体、快照导出、原片 Boston 591–592 的校正后切换、接缝刷新，共三项通过。初次新增的快照断言早于接缝准备，移至有效计划形成后复测通过。11 英寸 iPad 模拟器的 testDeghostToggleReusesRegisteredGeometry、testGridInspectorSelectionAndPanoramaWorkflow 均通过，后者实际检查新界面开关为关、开关往返以及全尺寸导出。此独立改动为本仓库实现，可单独回退。

## LCC-SKY · aaa6eccf

用户截图与 496–501 原片有 2,428 个一致的特征匹配点。截图中树梢间的亮天空，两个绿色感光点有些已到传感器白电平，红、蓝仍有有效读数。504–505 的饱和区域沿着远处树冠上沿。两组都使用随包 43XL 标定、自动求解的移轴量和白平衡，关闭防伪影。整次比较固定配准、曝光、输出尺寸和采样区域。

旧的预览只要下采样区域内有一个感光点饱和，就把对应颜色当作整块饱和。工作进程的 JSON 快照只保存 LCC 增益，导出会重新从全分辨率 Bayer 数据选取颜色参考。在细枝和天空相邻处，两种采样尺度会选到不同颜色，496–501 的导出因此出现明显的青绿色块。单独绕过高光重建后，该导出色块消退，但这两组接近饱和的天空都会产生新的颜色误差。

共享的 RAW 管线现在按实际饱和比例重建，以两个绿色感光点和其他未饱和通道按剩余余量连续估计亮度。局部颜色参考选自最亮的四分之一档有效测量。快照以两通道浮点网格保存预览的参考，旧快照缺少网格时会从相同尺度的 RAW 预览重建。修改覆盖 PhotonsPanorama 内的 LCCCameraPipeline、PanoramaLCC、PanoramaEngine，以及相应的合成与实拍测试。实现为本仓库原创，可以与 PANO-DEFAULT 分别回退。

### 实拍对照

表内为相同像素在预览和快照导出中的绿蓝比差异。数值是绝对对数差的第 95 百分位，单位为档。用未校正图的亮度、蓝红比和相邻像素亮度差选择平滑天空，避免让校正后的颜色反过来决定测量范围。导出从全尺寸 RAW 解码，量测图长边为 1,400 像素。

| 原片 | 树缘天空样本数 | 原实现 | 修复后 |
| --- | ---: | ---: | ---: |
| Holyoke 496–501 | 1,044 | 2.150 | 0.022 |
| Holyoke 504–505 | 6,860 | 0.0374 | 0.0065 |

另取有原始饱和读数的平滑天空，与邻近、亮度相近且感光点未饱和的天空比较绿色相对红蓝平均值的差异。在 496–501 的 747 个样本中，预览的第 95 百分位从 0.023 降到 0.017 档，导出从 1.533 降到 0.014 档。504–505 的 2,568 个样本中，预览从 0.037 降到 0.028 档，导出从 0.078 降到 0.018 档。个别树叶边缘仍受混合采样影响。这项测量用于对比空间连续性，现场没有独立的绝对色彩参考。

在隔离目录分别试验了原实现、停用高光重建、沿用一档宽的颜色参考、四分之一档参考，以及对重建值强制施加逐通道下限。采用四分之一档参考并保留连续加权估计。强制逐通道下限的方案使 496–501 的预览偏差增至 0.041 档。运行代码没有照片编号或为特定画面定义的区域。

### 回归与复测

- 在 macOS 上设置 PHOTONS_HOLYOKE_DIR 和 PHOTONS_BOSTON_DIR，再运行 `swift test -c release --filter 'HolyokeHighlightTests|LCCCameraTests|BostonRegistrationTests.testClippedSkyAfterLCCOnBoston593And594|PanoramaToneTests'`。包括两个实拍组、Boston 593–594、饱和比例、绿通道对称性、快照往返与兼容、损坏网格和亮度控制。此前 593–594 的天空中，6,819 个样本的红通道超过蓝通道者在本次预览和导出分别为 96 和 21 个。
- 新加的连续性测试最初一次跨过约 65 个传感器码值，却用单步阈值评判。已改成遍历相邻的 16 位码值，检查整个高光过渡及两个绿色感光点互换后的结果。
- 11 英寸 iPad 模拟器运行 testTraditionalAndProfileLCCUseTheSharedPipeline 和 testLCCCoverageCropUpdatesPreviewExportAndCanBeRemoved，两项通过。Holyoke 实拍对照运行于 Mac 的共享引擎。

## LCC-SKY-VERIFY · 成品与发布记录

本节所在提交可通过 `git log -1 --grep=LCC-SKY-VERIFY` 定位。范围仅为验收记录，依赖 aaa6eccf。定向 Mac Release 回归 16 项全部通过。接着运行 `swift test -c release --skip-build --filter PhotonsPanoramaTests`，88 项中 84 项通过，4 项按条件跳过，0 失败。跳过的是外部 HDR 全景 HEIC、外部已拼接照片、显式开启的标定文件生成、另一个私有 3FR 验收入口；上述 Holyoke 和 Boston 原片回归实际运行。

两组都在关闭防伪影、启用 LCC、使用相同快照的条件下，从各自的全尺寸 RAW 写出 16 位线性 Rec.2020 DNG，再用 ImageIO 和 CIRAWFilter 回读成品。下表为 RAW 主图的尺寸。

| 输入 | 输出尺寸 | 字节数 | 本地产物 |
| --- | ---: | ---: | --- |
| 496–501 | 21,338 × 20,228 | 1,604,992,169 | `local/out/lcc-sky-edge-035/accepted/496/panorama.dng` |
| 504–505 | 21,308 × 8,772 | 783,566,612 | `local/out/lcc-sky-edge-035/accepted/504/panorama.dng` |

将成品回读图与导出量测图配准，两组分别有 2,382 和 2,041 个一致匹配，缩放系数均为 1。496–501 树缘亮天空的 log₂(G/B) 中位数，预览为 0.056，成品为 0.058；504–505 分别为 0.221 和 0.223。两组在各自目录内保存了回读图。`local/out/lcc-sky-edge-035/496-tree-before-after.png` 为同一曝光下的预览与导出局部对比。

两端的本地 Release 版本为 0.3.5（10）。Mac 包为 `local/out/studio-035-sky-edges/Mac/Photons Studio.app`，包内源码标识 aaa6ecc。已通过 `codesign --verify --deep --strict`，并通过 Launch Services 启动新实例后正常退出。iPad 包为 `local/out/studio-035-sky-edges/iPadOS/Photons Studio.app`，Studio 身份 com.leoaokma.photons，arm64 设备构建使用 CODE_SIGNING_ALLOWED=NO。iPad 界面与共享引擎测试使用 11 英寸模拟器。本次交付为本地构建，未将构建 10 上传 TestFlight。
