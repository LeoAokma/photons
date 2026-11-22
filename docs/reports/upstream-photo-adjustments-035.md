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
