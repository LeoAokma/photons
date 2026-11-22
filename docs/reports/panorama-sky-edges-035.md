# 0.3.5 接片默认设置与天空树缘

| 编号 | 验收项 | 依赖 |
| --- | --- | --- |
| PANO-DEFAULT | Mac、iPad 新接片的防伪影默认关闭，原有任务保留开关 | 无 |
| LCC-SKY | 定位并验证 496–501、504–505 在预览和导出中的青色断层 | 用 PANO-DEFAULT 的新接片设置复现 |

## PANO-DEFAULT

Mac 和 iPad 都通过 PanoramaOptions 初始化接片。修改此处的默认值后，新建接片的防伪影开关为关。已有快照和清单继续读取各自保存的布尔值。防伪影可在原位开关，沿用同一组配准位置。没有改动接缝计算。

Mac 验证覆盖合成运动物体、快照导出、原片 Boston 591–592 的校正后切换、接缝刷新，共三项通过。初次新增的快照断言早于接缝准备，移至有效计划形成后复测通过。11 英寸 iPad 模拟器的 testDeghostToggleReusesRegisteredGeometry、testGridInspectorSelectionAndPanoramaWorkflow 均通过，后者实际检查新界面开关为关、开关往返以及全尺寸导出。此独立改动为本仓库实现，可单独回退。
