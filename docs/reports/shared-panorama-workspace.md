# Mac 与 iPad 接片工作区代码共享

| 追踪编号 | 可验收的改动 | 依赖 |
| --- | --- | --- |
| PANO-SHARED-01 | 两端从同一份配准结果判断是否需要重新配准、更新接缝或允许使用当前预览 | 个人 main 的双端防伪影实现 `74ac52a` |
| PANO-SHARED-02 | 接片与 LCC 入口使用同一个 SwiftUI 机身朝向选择器，两端保留各自的输入与布局 | 可独立回退，与 01 共用个人 main 基线 `b789b7b` |

## PANO-SHARED-01 · 接片预览状态 · `9fd8eff`

`PhotonsPanorama.PanoramaPlan.previewStatus` 比较当前配准模式、机位是否修改、已应用及待应用的接缝选项。Mac 和 iPad 在检查导出、更新预览时都使用这个判断。曝光、LCC 配置和裁切的导出条件仍由对应工作区核对。

Mac 在机位已修改时暂缓刷新接缝。iPad 在已经配准且仅修改曝光匹配或接缝柔度时显示「更新接缝」，直接使用已校正的预览更新混合，保留 LCC 和机位。预览有效时，两端勾选或取消防伪影会立即重算接缝。iPad 在配准确实完成后才接受新机位，取消重算时旧预览仍对应旧机位。

涉及 `PanoramaModel`、Mac 的 `PanoramaWindowModel`、iPad 的 `MobilePanoramaWorkspace`、`MobileWorkspaceModel` 和 `MobileEngine`，以及中英文动作名称和双端回归测试。可用 `git log --oneline --grep=PANO-SHARED-01` 定位实现提交。

**本次验证**

- 在 Mac 上以 `PHOTONS_BOSTON_DIR` 指向外部原片运行 `BostonRegistrationTests/testDeghostAfterLCCOnBoston591And592`。使用随包的 43XL、自动定位和不裁切的设置，B0000591 与 B0000592 的画布为 21285 × 8800，LCC 覆盖率为 100%。关闭防伪影后接缝权重发生变化，再开启恢复原权重；两次操作均保留机位、画布、配置文件与 LCC 偏移。此测试检查数值与预览生成，伪影的主观可见程度仍需看图判断。
- 同一轮 SwiftPM 测试还运行了 `PanoramaPerspectiveTests` 和 `PanoramaTests/testConsensusAvoidsTransientObjectAndMasksStayNormalized`，合计 5 项全部通过。
- Mac 另运行 `swift test --filter 'PanoramaTests|PanoramaPerspectiveTests|LCCPositionReferenceTests'`，75 项中 67 项通过，8 项因未设置专用外部素材或生成参数而跳过。591–592 回归已在上述单独配置素材的一轮实际运行。
- iPad Pro 13 英寸模拟器上，`testDeghostToggleReusesRegisteredGeometry`、`testCancelledRealignmentDoesNotAcceptAnOldPlan` 和 `testGridInspectorSelectionAndPanoramaWorkflow` 通过。最后一项从触控入口检查防伪影开关、曝光匹配、更新接缝、撤销机位、裁切和导出。该测试也发现了分组覆盖子控件无障碍标识的问题，本提交已修正并复测。
- 英文、简体中文资源均能解析，`git diff --check` 通过。iPad 使用生成的测试图，未在实体设备上运行。

## PANO-SHARED-02 · 机身朝向选择器

`PhotonsWorkspaceUI/PanoramaBodyOrientationPicker.swift` 统一绘制旋转后的移轴范围和零位十字，处理选择绑定、读屏标签和选中状态。Mac 显示与机身行程对应的不同朝向，使用单行标签；iPad 保留四个可点选的方向，角度和放置说明分行显示。宿主继续处理键盘、鼠标、触控、滚动和导航。以后修改朝向示意图只需改这个共享组件。

接入点共五处。Mac 的接片窗口、LCC 校正窗口和配置文件创建窗口，以及 iPad 的接片工作区和 LCC 工具页，均直接使用该组件。SwiftPM 的两个平台 UI target 依赖共享 target。iPad 的方框勾选样式保留在 `MobileCheckboxStyle.swift` 中。

移植来源为 Mac 的 `1eeea24`、`4406eff` 和 iPad 的 `d7a9ad6`、`ed5147b`。可单独回退本提交；共享配准判断仍可独立使用。

**本次验证**

- Mac 运行 `CameraBodySettingsTests`、`CameraBodyProfileTests`、`PanoramaBodyTests` 和 `LCCPositionReferenceTests`，17 项全部通过。覆盖 340 点宽面板中的控件布局、自定义机身、对称行程和旋转后的位置解算。
- iPad Pro 13 英寸模拟器的完整接片 UI 测试依次点选 90°、180°、270° 和 0° 并检查选中状态，完成移轴导出及透视预览。`testTraditionalAndProfileLCCUseTheSharedPipeline` 与 `testBundledProfilesUseMeasuredStopsOnIPad` 也通过，共 3 项。
- iPad 使用 Studio 的 xcconfig 完成 arm64 设备 Release 编译（无签名，Bundle ID 为 `com.leoaokma.photons`）。核对 Mac Release 资源包及 iPad Release 应用中两个镜头配置的 SHA-256，均与仓库原件一致。43XL 为 `d25fa4a33a1fc7fbd45849b29799362535b7abf80b3e1279411861dac509cd41`，80N 为 `b99a41830f51423cde2fff5409c83b1e42bd3a1e6c2b488c76f7593ce344de27`。
- `swift build -c release --product Photons` 通过，`git diff --check` 通过。交互验证使用 Mac 窗口和 iPad 模拟器；实体 iPad 触控与 VoiceOver 朗读未经人工验证。
