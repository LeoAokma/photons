# MAC-HISTORY-COUNT-01 · Mac 设置中的历史记录条数

「设置 → 通用 → 历史记录长度」的中英文文案误用 `%@` 占位符，导致四个选项显示同一段文字。将 `PhotonsLocalization/Resources` 中两种语言的 `settings.historyCount` 改为 `L10n.tr` 支持的 `{0}`。菜单显示 10、20、50、100 条记录，默认选择 20 条。此修复可独立回退，保留已有设置与历史数据。

## 验证记录

- 在修改资源前，新增的 `HistoryPreferencesTests.testHistoryDepthLabelsDisplayEachSelectableCount` 在中文环境下对四项均报错，实际值都是 `%@ 条记录`。
- 分别设置 `PHOTONS_LANGUAGE=zh-Hans` 和 `PHOTONS_LANGUAGE=en`，运行 `swift test --filter HistoryPreferencesTests`。两次均为 3 项通过，覆盖数字显示、选择持久化以及重新打开图库后的历史上限与撤销行为。
- 在 Apple Silicon Mac 上渲染实际设置页，逐一切换四个合法值。从界面图像读回中文的「10 条记录」至「100 条记录」及英文对应标签，共八个读数全部匹配。
- 使用 `swift build -c release` 构建本地 [Mac 应用](../../local/out/mac-history-count-01/Photons.app)。
