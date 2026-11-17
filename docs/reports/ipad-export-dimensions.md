# iPad 全景 DNG 尺寸修复

日期：2026-11-17。追踪编号：`IPAD-EXPORT-01`。

分支：`codex/ipad-export-dimensions`，基于本地缩放修复 `be6848d`。
用户要求继续本地开发，暂不提交 PR；本次未推送、未更新 TestFlight。
本修复及其测试、记录属于一个可独立验收的提交：
`fix(ipad): report full DNG panorama dimensions (IPAD-EXPORT-01)`。
可用 `git log --all --grep=IPAD-EXPORT-01` 查询提交。

## 实际原因与复现证据

用户选择 6000px 导出，但图库显示 512 × 367。检查模拟器中已有的全景 DNG：

| 数据位置 | 宽 × 高 | 用途 |
| --- | --- | --- |
| IFD0 | 512 × 367 | 内嵌 JPEG 缩略图 |
| SubIFD | 6000 × 4304 | 完整线性 DNG 图像 |
| 修复前图库记录 | 512 × 367 | 错误采用 IFD0 尺寸 |

`LinearDNGWriter` 正确写出了完整分辨率，原文件不需要重新导出。
`MetadataReader` 原来只读取 ImageIO 的索引 0；导出完成后自动导入图库时，
把缩略图宽高存进了 `assets.width/height`，iPad 网格直接显示这两个字段。

## 修改范围

- `PhotonsCatalog/MetadataReader.swift`：DNG 使用 `CIRAWFilter.nativeSize` 探测完整图像尺寸。
  不请求输出像素；探测失败或返回更小的回退预览时，保留原有 ImageIO 结果。
  普通 JPEG/TIFF 等格式及原始 EXIF/XMP 数据包保持原有读取行为。
- `PhotonsCatalog/DNGDimensions.swift`：修复已有图库里宽高均不超过 512px 的 DNG 记录。
  忽略不可访问文件，下一次打开图库可以重试；小尺寸原图不会被凭空放大。
  校正只写宽高，并用旧值条件避免覆盖并发更新。
- `PhotonsMobile/MobileEngine.swift`：每次打开图库执行一次校正，不在每次网格刷新时重复扫描。
  不修改原文件、评分、编辑历史、渲染版本或预览缓存。
- iPad 引擎测试及已有 Catalog JPEG 元数据测试补充回归断言。

## 本次验证

1. `swift test --skip-update --filter CatalogTests`：259 项通过，0 失败、0 跳过。
   同时验证共享 Catalog 在 macOS 上可构建，JPEG 尺寸及已有导入/编辑历史行为正常。
2. iPad Pro 13-inch (M5) 模拟器，iOS 27.2；Xcode 使用锁定的依赖版本：
   `-onlyUsePackageVersionsFromResolvedFile`，`CODE_SIGNING_ALLOWED=NO`。
   以下 3 项通过，0 失败、0 跳过：
   - `testDNGCatalogUsesFullSizeAndRepairsLegacyPreviewDimensions`：实际写入 6000 × 4304 DNG，
     确认缩略图为 512 × 367，新导入读取完整尺寸；模拟旧记录并通过重新打开图库校正；
     原文件 SHA-256、评分、编辑 JSON、历史游标、编辑时间和渲染版本保持一致，仍可撤销编辑，
     新引擎渲染次数为 0，重复修复无额外更新。
   - `testDNGDimensionRepairSkipsMissingSourcesAndSmallImages`：纵向 DNG、离线后恢复、
     小尺寸 DNG 和重复修复。
   - `testPanoramaAlignmentScaledLosslessExportAndMetadata`：完整拼接 → 缩放 DNG 导出 →
     自动导入 → 裁剪另存流程，断言缩放和全尺寸导出在图库中均显示完整图像尺寸。
3. 实际模拟器图库已自动从 512 × 367 校正为 6000 × 4304。
   对比前后记录，仅宽高改变；源文件 SHA-256 不变。
4. `git diff --check` 通过。依赖锁文件没有变化。

本地日志与结果包保留在忽略目录 `local/validation/`：
`catalog-tests.log`、`ipad-export-tests-2.log`、`export-dimensions-2.xcresult`，
以及实际图库前后对比 JSON。首次测试构建因新增测试缺少两个 `await` 失败，补齐后上述最终运行全部通过。
用户照片、图库记录和构建产物不进入 Git。

## 边界与回退

- 只在模拟器验证 iPad 运行，尚未通过真机/TestFlight 验证。
- 旧数据自动修复针对本次 512px DNG 缩略图问题；未扩展为全库所有 RAW 格式的元数据重建。
- macOS 共享的新导入读取逻辑同步修复；旧记录自动修复的调用目前限于 iPad。
- 外部查看器若只读取 DNG 的 IFD0，仍可能报告缩略图尺寸；完整图像数据一直存在于 SubIFD。
- 不更改 DNG 写出格式、HDR 映射或拼接像素内容。没有迁移数据库结构；回退代码仍能读取校正后的宽高。
- 基线包含本地缩放修复，但本次尺寸逻辑本身不依赖新的缩放算法；后续提交 PR 时需根据当时已合并基线整理。
