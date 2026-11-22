# 0.3.5 照片调整整合

## ADJ-UP-01 上游审计

对照 fork 起点 8dd0820 与 chemharuka/photons main 的 37d901bf。两端已有共用 Metal 显影管线、锐化和渲染域降噪。Mac 已有四轴透视和裁切工具，iPad 只有裁切和旋转。上游 #450 修复透视裁切重复映射，#489 增加自动裁切并修正旋转后的几何，#483 调整锐化位置。RAW 解码器提供单独的相机降噪参数。上游 #485 P1 是清洗服务与缓存层，尚未把其 Amount 混合接入预览与导出。此处按实际用户入口移植，保留 fork 的语言表、iPad 缓存、LCC、接片与 Web 导出。

## ADJ-CROP

移植 chemharuka/photons 5e58975c（#450）。CanvasCrop330、EditModel 和 Mac CropToolController 共用裁切坐标转换，打开已校正画幅和切换照片均只转换一次。与其他移植独立，可单独回退。

本次 swift test --filter CropReentryAfterAspect450Tests 四项通过，包括旧算法复现、源坐标迁移、画布裁切重开和换图。该项只改变 Mac 裁切工具及共享迁移。

## ADJ-GEOMETRY

移植 chemharuka/photons b8894229（#489 的方向变换）。GeometryGroup 在旋转与镜像时同步重算裁切、引导线、透视和比例，Mac 菜单、裁切草稿及 iPad 方向控件使用同一算法。旧文件在下一次手动变换时生效，独立于 #450。

本次 swift test --filter 'GeometryRemap489Tests|CropReentryAfterAspect450Tests' 的 13 项通过，11 英寸 iPad 模拟器 xcodebuild build 成功。未实机核验所有镜像组合。

## ADJ-PERSPECTIVE

iPad 变换页接入 Mac 与上游 861e5939（#502）既有的垂直、水平、剪切与宽高比校正，使用同一个 PerspectiveMap、文档、预览和导出管线。百分数对应模型的 0.01 步长。涉及 MobileInspector 和本地化，可独立回退。

11 英寸 iPad 模拟器 build 成功。PerspectiveAspect408Tests 和 PerspectiveMapShear407Tests 共 12 项通过，PerspectiveRange347Tests 的范围、几何和可逆检查通过；其中旧像素金值测试五个 SHA 与本机渲染不符，保留原断言和记录。此提交没有改动渲染算法。

## ADJ-AUTOCROP

移植 chemharuka/photons b8894229（#489 自动裁切）。把有效像素多边形与裁切求解放入 PhotonsCore，Mac 裁切工具和 iPad 变换页都写同一个可撤销文档操作。已水平照片保留原有构图，已应用的结果不会重复新增历史。裁切用转正后的原始分辨率，支持 90° 旋转及透视画布。依赖现有几何字段，可独立回退。

本次 AutoCropSolver489Tests 四项通过，含相对穷举面积检查和转过 90° 的非正方形文档，CropReentryAfterAspect450Tests 四项通过；11 英寸模拟器 build 通过。未实体设备测量。

## ADJ-SHARP

移植 chemharuka/photons 2d089216（#483），含 #475、#481 和 #484 的局部性与阶段测试。Mac 和 iPad 共用的 Stage、DecodeInputs 与版本指纹把锐化安排在局部蒙版前，零锐化在无条件链上也按线性域次序应用暗角。预览和导出消费同一管线，旧预览通过版本指纹失效。独立于裁切；回退会恢复旧锐化和缓存指纹。

本次运行锐化、阶段形状、缓存版本、局部色彩及相关渲染套件。局部曝光和饱和度各有 648/648 个选区内像素变化，选区外最大 0 码。英文环境的两条历史中文断言和两条待适配的夹具，在恢复 fork 的快照约定、更新暗角线性域金值并指定 PHOTONS_LANGUAGE=zh-Hans 后全部复测通过。部分旧测试需要本机未提供的 L1030433.dng，未重录其 RAW 金值。

## ADJ-NOISE

移植 chemharuka/photons c19825a9、16aa3d32 和 ae9ab88c，使用其 MIT NonlocalMatchFilter 694d505 源码。原先对所有照片固定使用 0.70 强度；现有 Mac 模型降噪任务按当前 RAW 实测噪声求取强度。两端包引用同一版本，原有模型与权重继续使用。此改动独立，可连同两个 lockfile 一起回退。

本次 NLMFDenoiseJobTests 10/10 通过，包括模型加载、打包位置和自动强度设置；11 英寸 iPad 模拟器 build 成功。该提交更新已有模型任务，未在实体 iPad 运行全尺寸推理。

## ADJ-NOISE-IPAD

把 fork 与上游共用的 DetailSettings / CIRAWFilter 五项解码调整接入 iPad，依据为 upstream/main 37d901bf 的 InspectorView.detailCard。亮度/色彩降噪、解码细节、解码锐化及去摩尔纹读取当前 RAW 的真实支持标记和默认值。MobileEngine 把这些值及拍摄白平衡写入预览缓存；SDR/HDR、缩略图、重启后的磁盘命中都能正确显示，普通位图不会出现 RAW 参数。旧预览按需更新。独立于模型降噪。

11 英寸模拟器上 testRAWControlDefaultsAndCapabilitiesSurvivePreviewCache 和 testZoomDetailMatchesEditedFullResolutionPixels 均通过。新生成 DNG 的控件值逐项对照实际解码，再验证复用磁盘预览时渲染次数为零。未在实体机覆盖所有相机型号。

## ADJ-RESET-MAC

为 NSSlider 添加 AppKit 双击识别，拖条与参数名称共用同一个逐项复位动作。覆盖主检查器、白平衡、修复控件以及接片曝光/高光，保留原有单击、拖动、键盘和数值输入。双击的第一次按下不会额外提交一次调节，撤销可直接回到双击前。独立实现，没有外部移植，可单独回退。

本次 PHOTONS_LANGUAGE=zh-Hans swift test --filter 'AdjustmentSliderTests|PanelResetTests|PanelResetScopeTests' 通过。实际向 AppKit 窗口发送轨道上的两次鼠标事件，检查只触发一次复位且没有拖动提交；既有键盘、辅助功能、卡片和参数作用域测试也通过。未使用实体触控板手工测试。

## ADJ-RESET-IPAD

MobileSlider 的标题和拖条都支持双击，数值输入框保留文字编辑。曝光、锐化、降噪、色彩、透视与裁切按各自文档默认值复位；白平衡和 RAW 解码参数清除单项覆盖，回到相机默认。接片曝光和 HDR 高光只复位所触及的一项。文档修改沿用现有渲染、保存和撤销。依赖 ADJ-NOISE-IPAD 和 ADJ-PERSPECTIVE 提供对应行；手势是 fork 原创。

11 英寸 iPad 模拟器通过 testDoubleTapExposureTrackAndTitleResetOnlyExposureAndUndoRestoresIt 和竖屏调整底栏回归。真实 UI 先改色温再改曝光，双击轨道归零、一次撤销回到之前曝光，双击标题再次归零，全程色温不变。未在实体外接鼠标上复测。
