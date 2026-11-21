# Mac 新文件夹导入后的 502–505 接片与初始预览

2026-11-21，在 Apple Silicon Mac 上核对个人 fork 的本地 `main`。本次起点为 `068f8c6`。两项修复可以分别审查和回退。

| 追踪编号 | 提交 | 验收目标 | 依赖 |
| --- | --- | --- | --- |
| PANO-PATH-01 | `d5a5ec6` | 选择「源文件夹」时，即使上次记住的导出目录不存在，也能在原片旁写出接片 | 无 |
| PREVIEW-IMPORT-01 | `48511bf` | 导入数亿像素的全景 DNG 时，为正常解码留出足够时间，并保留超时保护 | 无 |

## PANO-PATH-01

最新一次导入在图库中登记了 84 个文件。B0000502.3FR 至 B0000505.3FR 均可读取。导出面板保存的目的地是「源文件夹」，另一个已记住的目录不存在。原实现给两者都创建书签，因未使用的路径触发 Cocoa 错误 260，接片子进程尚未启动。

`PanoramaJob` 统一按文件名自然顺序取第一张照片的父目录，或按设置返回选定目录。`PanoramaExport` 和 `BackgroundTasks` 使用同一规则做可写性检查、获取访问权、创建书签和选择临时输出位置。现有任务数据格式兼容。

新测试 `PanoramaBackgroundExportTests.testExportUsesOnlyTheSelectedDestination` 在旧实现上复现错误，修复后在两种导出模式下均通过。测试调用真实后台进程，检查子目录、输出 DNG、内嵌清单和未选目录是否被误建。运行以下测试与构建。

```sh
PHOTONS_LANGUAGE=zh-Hans swift test --filter 'PanoramaBackgroundExportTests|BackgroundTaskCancellationTests|PanoramaJobTests|PanoramaHDRTests'
swift build -c release
```

12 项测试通过，2 项依赖额外 Boston RAW 的用例跳过，Release 构建成功。另用四张实际原片的副本，经 Mac 接片视图模型完成移轴配准和 APO-Digitar 43XL + iiic LCC 自动校正，将冻结的方案提交给 Release 应用包内的后台进程。验证使用不存在的已记住目录、以源文件夹为目的地并导出全尺寸线性 DNG。

重新打开成片得到 **21,323 × 14,094**，四个输入文件名全部在内嵌清单中。校验了 4,704 个无损 JPEG 图块的偏移、长度和开始/结束标记，最后一个图块恰好到达文件末尾。DNG 为 1,123,456,003 字节，内嵌预览显示湖畔秋景。已将 [B0000502_pano.dng](../../local/out/pano-502-505-d5a5ec6/B0000502_pano.dng) 存在独立输出目录。

## PREVIEW-IMPORT-01

对同一图库的隔离副本逐张生成高清预览。在旧策略下，84 个文件中有 5 张已有的全景 DNG 超过统一的 30 秒时限：B0000444-Pano、B0000469-Pano、B0000487-Pano、B0000496-Pano 和 B0000502-Pano。四张要接片的 3FR 均生成预览。原截图只保存失败总数 4，无法还原当时各文件的结果；超时数量会随机器负载变化。

`PhotonsCatalog/ThumbnailService` 依据图库中记录的原始像素数计算高清预览时限，默认每一亿像素给 30 秒，下限 30 秒、上限 240 秒。基础嵌入预览与未知尺寸的请求使用原时限。无需重新探测文件尺寸。`ThumbnailProvider`、`PreviewPreparation` 和 `PreviewHistogramService` 在提交时传入图库记录。队列仍按原有并发策略运行。

```sh
PHOTONS_LANGUAGE=zh-Hans swift test --filter 'ThumbnailServiceTests|PreviewCacheManagementTests|PanoramaBackgroundExportTests'
swift build -c release
```

29 项调度与缓存服务测试、4 项 UI 模块测试通过。新增测试覆盖约 4.3 亿像素的慢预览、时间上限、小图、嵌入预览及缺少尺寸的情况。已有挂起测试验证超时后队列能继续。另以真实的 `PreviewPreparation` 在独立图书馆副本与空缓存上运行该批次，任务正常结束，84 个不同的文件均有非空的高清 JPEG 预览（63 个 3FR、14 个 DNG、7 个 JPG）。旧策略下超时的 5 个文件全部成功。

## 本地交付

[Photons.app](../../local/out/mac-main-48511bf/Photons.app) 的内嵌版本为 `48511bf`。主程序为 arm64，已通过 `plutil -lint` 和 `codesign --verify --deep --strict`。包内已核对接片、HDR、Ansel 可执行文件与 Ansel 模型。实片验证使用的后台接片程序与交付包内文件 SHA-256 相同。此版本也包含[此前的设备调度、连续双击与直方图调整](mac-scheduling-zoom-histogram.md)。

验证使用图库副本、单独的预览缓存及原片副本。接片回调校验输出文件，跳过写入用户正在使用的图库。未在 Intel Mac、外置卷或商店沙盒下重测。
