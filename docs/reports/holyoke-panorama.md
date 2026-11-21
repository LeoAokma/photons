# Holyoke panorama investigation

Tracking baseline is ed54df7 on the fork main. Local probes read the CFV 100C originals and the bundled 43XL profile. Intermediate rasters and personal photographs stay outside Git.

## 交付记录

| 编号 | 提交 | 独立改动 |
| --- | --- | --- |
| LCC-SKY-01 | `e092156` | 原片基线与天空残色诊断 |
| LCC-HIGHLIGHT-01 | `97acbba` | 修复 474 高光重建造成的色带 |
| LCC-OVERLAP-01 | `03f30f6` | 对 LCC 后的剩余帧间色差执行重叠匹配 |
| PANO-ALIGN-01 | `4731abb` | 复核窄条特征，修正 467 的错位 |
| SHIFT-AXIS-01 | `1fda4c6` | 配准和 LCC 支持逐轴提示及标定端点 |
| SHIFT-AXIS-MAC-01 | `53c33f4` | Mac 逐轴输入及可选的整组基准 |
| SHIFT-AXIS-IPAD-01 | `d60ed4d` | iPad 逐轴输入、拖动、撤销及自动识别 |
| VERSION-035 | `73492d6` | Mac 与 iPad 的产品版本统一为 0.3.5 |

最终在 Mac 上运行 `PHOTONS_LANGUAGE=zh-Hans swift test --filter 'PhotonsPanoramaTests|PanoramaPerspectiveTests'`，共 83 项，其中 75 项通过，8 项因外部样片或可选生成条件跳过，零失败。iPad 模拟器的完整界面流程在最后一次布局修订后再次通过。Mac 的 0.3.5 包通过签名检查和 Launch Services 启动检查。iPad 的模拟器包和未签名设备包均已编译并回读版本。四组个人照片仅用于本机验证。对照截图、测量脚本和缩放导出保存在本机，已移除 2.30 GiB 的临时浮点缓冲。

## LCC-SKY-01 · Real-input diagnosis

- 496–501 register into a 21338 × 20228 canvas. Scene-based LCC gives offset (−0.04, −3.23) mm, 99.78% footprint coverage and 9109 K / +8.86 tint, with zero paired flats. Coverage measures where calibration samples exist. It does not measure chromatic accuracy.
- 478–479 and 480–481 form separate translation pairs. The median same-scene sky chromatic disagreement after LCC was 3.43 and 3.41 log-percent respectively. The five available originals from 478 through 482 failed as one shift set. The 477 original was absent at investigation time. 479/481 do match perspectively, with a 59-pixel 90th-percentile error from a constant translation at 960 pixels wide.
- In 496–501 the same disagreement was 2.33 log-percent with a 6.94 log-percent 90th percentile. The release code disables residual RGB matching with any active LCC. In an isolated comparison, running the existing overlap fit on corrected previews reduced those values to 1.42 and 3.43. For 478–479 and 480–481 the medians fell to 0.82 and 0.70. Scalar exposure changes cancel in this metric. This identifies a software contribution to differences between frames. Unpaired scene colours, especially the absolute hue of the sky outside an overlap, cannot establish the accuracy of a flat field or white balance.
- In 474–475 coverage is 100%. The green/grey band can already be reproduced in frame 474 before compositing, well outside the overlap. With identical geometry, field, offset and WB, changing only RAW clipped-colour reconstruction reduced the adjacent-pixel log-chroma jump at x=575 (960-wide proxy, y=160…215) from 0.402 to 0.158. The original estimator rejected coloured neighbours and could switch abruptly to a scene-wide neutral. The original hue in a fully saturated channel remains unknown.

The baseline probe runs the optimized PhotonsPanorama module from ed54df7. It analyzes the originals, prepares CFA images, solves with the bundled profile and applies cropping and shared auto WB. Resample the individual linear RGB previews to 960 × 720. Compare positive, smooth, non-border overlap samples at identical panorama coordinates on a separate 3.7-pixel grid. The metric is 100 times the larger absolute difference in log R/G and log B/G. The sky proxy additionally selects blue-dominant pixels in the top 55% of the canvas. Sample counts for 496–501, 478–479 and 480–481 are 7592, 1609 and 2207. In 474–475 only 14 overlap samples pass the sky cut, so the isolated-frame control is the relevant test. No ground-truth white plate or full-resolution export was used.

### Clarified second group

The intended set is **482–487**. All six RAWs were available. On the original baseline the six registered at 21324 × 17081, with 98.5% LCC coverage, zero paired flats and scene WB 10422 K / +7.75. The 10543 smooth blue overlap samples gave median / P90 chromatic disagreement of 11.80 / 17.57 log-percent after LCC. The isolated residual matching candidate reduced this to 2.96 / 7.22. The 478–481 measurements remain ancillary controls.

## LCC-HIGHLIGHT-01 · RAW highlight colour

Local reconstruction now uses the surrounding measured colour for partial and full clipping. With no usable local colours the estimator retains the illuminant fallback. Compared original and candidate in the single corrected 474 frame at the same HDR exposure. At x = 540, 575 and 610 (960-wide frame) the jumps along the sky boundary fell from 0.440 / 0.402 / 0.318 to 0.138 / 0.158 / 0.093. Some variation remains. A clipped sensor channel supplies no absolute colour reference. Shared preview and export implementation in LCCCameraPipeline.swift. Six LCCCameraTests passed including the new blue-neighbour and fallback checks. Baseline investigation commit e092156.

## LCC-OVERLAP-01 · Residual matching after lens calibration

With overlap exposure matching enabled, PanoramaSeams now fits the same bounded RGB residual fields to corrected frames that it previously fitted only to uncorrected frames. Its inputs are the corrected preview pixels. The existing snapshot, manifest and full-size compositor carry those fields. Disabling the option clears them. Per-frame correction and residual matching address different stages. The real-input A/B figures above use the baseline geometry and WB. They do not guarantee neutral absolute sky colour. The isolated 474 highlight fix is 97acbba and can be reverted independently. The shared panorama test selection ran 75 tests, 8 conditional skips, zero failures.

## PANO-ALIGN-01 · Wire-supported false translation, frames 464–469

The 466/467 edge received a 0.994 coarse correlation from five anchors spanning only 12 × 116 pixels along a wire. The original tree placed 467 about 600 native pixels too high and LCC then rejected the layout as exceeding body travel. Independently, contrast-equalized SIFT on registered 960 × 720 inputs found 331 agreeing 464/467 translations with median (+2.38, −542.15) pixels. The old vertical prediction was −592.07 pixels and the new one is −542.98. The corrected six-frame canvas is 21347 × 20261. LCC solved normally and covered 99.49%.

Sparse matches narrower than a descriptor are rechecked with spatially distributed, lower-contrast corner candidates. A first prototype that changed feature selection everywhere failed cycle checks in three groups and was discarded. The selective retry reproduced the original poses in 474–475, 482–487 and 496–501. Targeted translation, projective and panorama tests ran 17 tests with one optional skip and zero failures. This is a shared registration change, independent of the corrected-frame RGB matching in 03f30f6. Parallax or moving subjects can still differ locally.

## SHIFT-AXIS-01 · Shared shift guidance

Each frame can specify either axis independently as unknown, a signed millimetre value or the negative/positive end stop. End stops resolve against the current oriented body and calibration. An explicit numeric value stays literal. Compatible per-axis origin estimates bound the LCC search to the intersection of their ±1.5 mm windows and physical travel. Contradictory hints reopen the affected axis. For registration a pair of coordinates on the same axis limits the descriptor search to a strip. Insufficient image support triggers unrestricted matching. A perspective fallback is also judged on its image evidence.

15 targeted tests ran with two conditional skips and zero failures. New cases check a 90° body, measured versus nominal travel, independent axes, inconsistent guidance and recovery of the true image translation with deliberately incorrect two-axis readings. Using only left/right maximum readings on the six 464–469 originals produced a valid 21347 × 20261 layout and LCC solve with Y free. Depends on the registration verifier in 4731abb. Clients with the existing full-point API are supported.

## SHIFT-AXIS-MAC-01 · Mac position sheet

Click a photo in the shift diagram. Each axis has independent Unknown, Specific value and two directional Maximum choices. End stops display their resolved millimetres. The optional explicit absolute reference requires both axes. Partial hints go to the automatic LCC solver. Clearing a hint removes it from subsequent matches. Shared SwiftUI editor, Mac window model, English and Simplified Chinese resources. Tested with 4 Mac workspace tests and 3 shared guidance tests, all passed. Depends on 1fda4c6. Pending edits are per stitch session.

## SHIFT-AXIS-IPAD-01 · iPad position controls

The iPad diagram keeps its inferred positions separate from user-entered axes. Its selected frame uses the shared editor. Dragging updates the axes that actually moved. Revert restores the applied layout. The LCC and registration workers receive only supplied axes and end-stop measurements are resolved with the selected profile. The existing explicit full-position anchor is available when both axes of the selected frame are supplied. Depends on 1fda4c6 and the editor in 53c33f4.

On the 13-inch iPad Pro simulator the engine alignment/export and physical dragging tests passed. The workspace UI workflow also passed, including choosing Maximum right, retaining the other axis, reverting, adjusting seams and exporting. A generic iPadOS Release device build succeeded with signing disabled. No physical iPad was exercised.

## Cross-checks

- Holding geometry and calibration fixed, switching only scene WB to the as-shot WB changed sky colour substantially. In 496–501 the scene estimate was 9109 K / +8.86 versus as-shot 6189 K / −13.42. The scene setting raised the median linear R/G by 50% and lowered B/G by 17% in smooth blue samples of 496/497. For 482–487 the estimates were 10423 K / +7.74 and 5770 K / −12.10. The corresponding changes were +66% and −29% in 486/487. This establishes sensitivity to the illuminant estimate, without a neutral reference to choose between them.
- The integrated build with horizontal end stops alone registered 464–469, 482–487 and 496–501. Repeating the sky residual comparison on these final 482 and 496 layouts yielded median values of 2.98 and 1.40 log-percent.
- Serialized and reopened the actual worker snapshot on 474–475 and 496–501. Rendered from full-resolution CFA sources into scaled linear half-float TIFFs of 1500 × 609 and 1500 × 1426. All inspected output values were finite. Linear peaks were 3.50 and 2.52. These were scaled output checks.

## VERSION-035 · Product version

The Mac bundle template and iPad app configurations now declare product version 0.3.5. The macOS distribution tool reads its default from the bundle template. This change is independent of the panorama pipeline. A local parser test verified the default with distribution actions mocked. The built macOS app, iPadOS Release device app and Debug simulator app all reported 0.3.5 in their generated Info.plist. The Mac package passed strict recursive signature verification and launched through Launch Services. The device build was unsigned. Historical release records retain the versions that shipped.
