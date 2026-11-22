# 593–594 的 LCC 高光伪色

## PANO-GHOST-01 · 共享 RAW 高光重建

在 fork main 的 edf5f3e 上读取 Boston 的 B0000593.3FR 和 B0000594.3FR，使用内置 43XL 镜头配置、Alpa 12 Max 机身、0°、自动定位、自动白平衡，关闭裁切。在同一次配准结果上交叉切换 LCC 与防伪影。画布为 21,296 × 8,802，两帧位置和 LCC 偏移保持固定。

在 1,000 × 414 的线性光栅中，检查 x ∈ [551, 686)、y ∈ [5, 70) 的天空，并用未校正画面的 G > 0.38 排除枝叶阴影。得到的 6,761 个像素全部由 593 单独供图，LCC 开启后，防伪影两种设置在此处逐像素相同。未校正时该区域的红蓝比中位数为 −1.10 EV；旧高光重建将其推到 +0.66 EV。在粉色最明显的位置，RAW 的两个绿通道及部分蓝通道已饱和。

原来的局部颜色估计既接收暗树叶，也接收跨越剪影边缘的 Bayer 采样块。这些块的红、绿、蓝采样点可能来自两个不同物体。隔离试验先限制参考曝光，消除了预览的大块红色；在序列化后重新解码全分辨率原片，边缘仍有残色。再排除周围同色采样点出现明显跳变、或邻域已饱和的参考块后，云层在两条路径均恢复平滑。

改动集中于 PhotonsPanorama 的 LCCClippedColorMap。每张 RAW 按自身可用样本的最高曝光取一档，使用平滑且未饱和区域的校正后通道比值进行原有空间插值。相邻 Bayer 块检查半径固定。设抽样块数为 S，网格大小为 G，两遍扫描为 O(S)，原有 100 轮网格插值为 O(100G)。新增存储为常数。图像配准、接缝选择、白平衡和导出格式继续沿用原流程。

修复后同一批天空像素的红蓝比中位数为 −0.68 EV，红高于蓝的比例从 77.87% 降到 1.02%。这是本图固定区域的复现指标。无法从饱和的传感器通道获知原始颜色。对于缺乏可用参考的场景，仍使用已有白平衡回退。

新增的 LCCCameraTests 合成了不同曝光下的冷、暖高光及穿过高光的暗前景，各自具有已知的通道比例。旧引擎在 4 种组合中均失败。最终隔离候选通过 7 项 LCCCameraTests。本项没有前序功能依赖，未移植外部实现。

## PANO-GHOST-02 · 实拍回归与本地交付

| 追踪编号 | 提交 | 内容 |
| --- | --- | --- |
| PANO-GHOST-01 | 7631b01 | 在 Mac 和 iPad 共用的 RAW 管线中筛选高光颜色参考，附合成回归 |
| PANO-GHOST-02 | 本记录所在提交，可用 git log --grep=PANO-GHOST-02 -- Tests/PhotonsPanoramaTests/BostonRegistrationTests.swift 定位 | 593–594 的实拍像素回归、实际导出、两端成品验收 |

PANO-GHOST-02 依赖 7631b01。新增的 BostonRegistrationTests.testClippedSkyAfterLCCOnBoston593And594 从已渲染的 UI 预览取样，并在 JSON 快照往返后重新解码两张原片。两条路径使用同一份由未校正预览确定的天空掩码。此处经过预览重采样，共选中 6,819 个像素；预览和导出路径分别有 86、22 个像素红色高于蓝色。素材通过 PHOTONS_BOSTON_DIR 显式提供，仅作为输入；测试使用临时目录安装随包配置。

另写出 21,296 × 8,802 的全尺寸 16 位线性 DNG，ImageIO 读取尺寸、位深及两帧清单，Core Image 重新解码成品检查相同天空。输出为 700,660,588 字节。实拍对比图来自同一曝光下的序列化快照导出，修复前后使用相同的配准位置、白平衡和 LCC 位置。

Mac Release 上，LCCCameraTests、既有防伪影用例与 PanoramaToneTests 共 12 项，首次运行 11 项通过，1 项等待外部素材。设置 PHOTONS_BOSTON_DIR 后运行 593–594 高光、591–592 防伪影和 628–633 六帧亮度，3 项全部通过，包含首次跳过的用例。

工作区内的成品如下。

- `local/out/boston-593-594/final/comparison.png` 为修复前后局部对比，`final/dng-readback.jpg` 为完整成品的回读预览。
- `local/out/boston-593-594/final/B0000593_pano.dng` 为修复后的全尺寸成品。
- `local/out/studio-035-lcc-highlights/Mac/Photons Studio.app` 为本地 Mac 0.3.5 (8)，已完成 Release 编译、严格签名校验及空库启动退出。
- `local/out/studio-035-lcc-highlights/iPadOS/Photons Studio.app` 为 Studio 身份的 arm64 iPad 0.3.5 (8) 设备 Release 包。iPad Pro 13 英寸（M5）模拟器上，共享 LCC、切换防伪影两项测试通过。设备包采用无签名构建；本次验证使用模拟器，未在实体 iPad 验收或上传 TestFlight。

实拍验收与合成测试可以独立回退。原始实现和回归均在本仓库编写。
