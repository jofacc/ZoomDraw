# ZoomDraw

![version](https://img.shields.io/badge/version-2.1-blue) ![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![license](https://img.shields.io/badge/license-MIT-green)

一个轻量的 macOS 屏幕**放大 + 画笔标注**小工具。

- 菜单栏常驻，不占 Dock
- 全局快捷键，可在偏好设置中自定义
- 放大状态下左键单击暂停，自动启用画笔叠加标注
- 原生 Swift + AppKit，单文件二进制 ~250 KB
- 支持 macOS 13+，已在 macOS 15 上测试

---

## 默认快捷键

| 操作 | 快捷键 |
|---|---|
| 开/关 **放大模式** | `⌥ A` |
| 开/关 **画笔标注** | `⌥ D` |

> 在菜单栏 → **偏好设置…**（`⌘,`）中自由修改。

### 放大模式
- 鼠标移动：跟随焦点
- 滚轮 / `+` `-`：调节倍率（1× – 8×）
- **鼠标左键单击**：暂停画面（自动进入画笔标注层）
- `ESC`：退出

### 放大暂停后（画笔叠加）
- `H` 或 `Tab`：隐藏 / 显示画笔层
- 鼠标拖拽：绘制
- 颜色：`1` 红 · `2` 黄 · `3` 绿 · `4` 蓝 · `5` 白
- 工具：`A` 自由 · `B` 矩形 · `C` 椭圆 · `D` 箭头
- 笔触：`[` 减小 / `]` 增大
- `Z` 撤销 · **`X` 清空当前画面**
- `ESC` 退出

### 独立画笔标注
- 操作同上；`ESC` 退出

> ⚠️ 首次使用「放大」时，macOS 会请求**屏幕录制**权限：
> 系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 ZoomDraw → 重新启动应用。

---

## 安装

下载 [Releases](../../releases) 中最新版本的 `ZoomDraw-x.x.x.dmg`，打开拖入 Applications。

> 因为是临时签名（ad-hoc），首次启动时按住 `⌃` 右键点击 → 打开 → 允许。

---

## 从源码构建

```bash
git clone <this-repo>
cd ZoomDraw
bash build.sh
```

产物位于 `dist/`：
- `ZoomDraw.app` — 应用本体
- `ZoomDraw-2.1.0.dmg` — 分发镜像

---

## 项目结构

```
.
├── Sources/ZoomDraw/
│   ├── main.swift               # 入口
│   ├── AppDelegate.swift        # 菜单栏与协调器
│   ├── HotkeyManager.swift      # Carbon 全局快捷键
│   ├── HotkeyConfig.swift       # 快捷键持久化
│   ├── PreferencesWindow.swift  # 偏好设置 UI
│   ├── ZoomController.swift     # 屏幕捕获（ScreenCaptureKit）
│   ├── ZoomWindow.swift         # 全屏放大 + 画笔叠加
│   ├── DrawController.swift
│   ├── DrawWindow.swift         # 透明画布
│   └── Stroke.swift             # 共享笔迹模型与渲染器
├── Resources/Info.plist
├── Package.swift                # SwiftPM（备用）
├── build.sh                     # 一键打包 .app + .dmg
├── LICENSE                      # MIT
└── README.md
```

---

## License

MIT © 2026 [tywinliu](https://github.com/tywinliu)
