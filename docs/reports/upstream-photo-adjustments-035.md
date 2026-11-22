# 0.3.5 照片调整整合

## ADJ-UP-01 上游审计

对照 fork 起点 8dd0820 与 chemharuka/photons main 的 37d901bf。两端已有共用 Metal 显影管线、锐化和渲染域降噪。Mac 已有四轴透视和裁切工具，iPad 只有裁切和旋转。上游 #450 修复透视裁切重复映射，#489 增加自动裁切并修正旋转后的几何，#483 调整锐化位置。RAW 解码器提供单独的相机降噪参数。上游 #485 P1 是清洗服务与缓存层，尚未把其 Amount 混合接入预览与导出。此处按实际用户入口移植，保留 fork 的语言表、iPad 缓存、LCC、接片与 Web 导出。

## ADJ-CROP

移植 chemharuka/photons 5e58975c（#450）。CanvasCrop330、EditModel 和 Mac CropToolController 共用裁切坐标转换，打开已校正画幅和切换照片均只转换一次。与其他移植独立，可单独回退。

本次 swift test --filter CropReentryAfterAspect450Tests 四项通过，包括旧算法复现、源坐标迁移、画布裁切重开和换图。该项只改变 Mac 裁切工具及共享迁移。

## ADJ-GEOMETRY

移植 chemharuka/photons b8894229（#489 的方向变换）。GeometryGroup 在旋转与镜像时同步重算裁切、引导线、透视和比例，Mac 菜单、裁切草稿及 iPad 方向控件使用同一算法。旧文件在下一次手动变换时生效，独立于 #450。

本次 swift test --filter 'GeometryRemap489Tests|CropReentryAfterAspect450Tests' 的 13 项通过，11 英寸 iPad 模拟器 xcodebuild build 成功。未实机核验所有镜像组合。
