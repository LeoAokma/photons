# Mac 最近照片库

| 追踪编号 | 验收目标 | 依赖 |
| --- | --- | --- |
| LIB-RECENT-01 | 从“文件”菜单选择历史照片库 | 无 |
| LIB-RECENT-02 | 从空白图库直接打开照片库，或选择最近记录 | LIB-RECENT-01 |

## LIB-RECENT-01

在 AppMenu 的“打开库…”下添加最近照片库子菜单。每次展开时从 LibraryHistory 读取记录，最近使用的排在最前面，同名时显示路径。菜单项目携带库 URL，通过响应链交给当前 EditorWindowController，沿用现有的书签与错误处理。没有记录时显示禁用的提示。中英文文案随应用语言切换。

本次运行 `PHOTONS_LANGUAGE=zh-Hans swift test --filter 'RecentLibraryUITests|OutputModeAndLibraryTests|ImportUITests'`，24 项全部通过。在临时目录创建两份同名图库，核对菜单顺序、按路径区分、移除后的更新及选中后打开的真实库。验证了原有导入快捷键。未用个人图库进行写入测试。此项可独立回退，空白图库入口复用了这里的菜单。
