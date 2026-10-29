# NotchLauncher

[![Release](https://img.shields.io/github/v/release/BiBoyang/NotchLauncher)](https://github.com/BiBoyang/NotchLauncher/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20%E5%B8%A6%E5%88%98%E6%B5%B7%E7%9A%84%20MacBook-black)

把 MacBook 刘海变成一个应用启动面板:鼠标悬停刘海展开面板,点击图标启动/激活应用。纯 AppKit + SPM,无第三方依赖。

![NotchLauncher 演示:悬停刘海展开面板,移开自动收起](docs/demo.gif)

## 功能

- **悬停展开**:鼠标移到刘海区域,面板自动下拉展开;移开自动收起
- **点击启动**:点击图标启动应用;已运行则激活置前
- **位置固定**:图标严格按配置顺序排列,不因应用启停而跳动;运行中的应用图标全彩并带小圆点,未运行的淡化
- **两行网格**:每行默认 8 个图标(3–10 可配),最多显示 2 行,超出部分纵向滚动
- **可见数量上限**:最多添加 16 个可见应用,达到上限会提示;旧配置中的超额条目保留,不会被自动删除
- **拖入添加**:从 Finder/Dock 拖 `.app` 到刘海,面板展开后松手即添加(自动读取名称/bundleID,重复条目自动跳过)
- **拖动排序**:在面板内直接拖动图标即可调整顺序,其他图标实时让位,松手写回配置
- **拖出删除**:把面板里的图标拖出面板区域(越界超过 24pt)松手即删除;面板内松手或小幅误拖自动回弹不删
- **图标右键菜单**:右键单个图标 → 打开 / 退出 / 强制退出(运行中)/ 在 Finder 中显示 / 隐藏 / 从面板移除
- **面板菜单**:面板空白处右键 → 添加应用… / 设置… / 查看并恢复已隐藏应用 / 编辑配置文件 / 重新加载 / 退出
- **偏好设置**:图形化调整延迟、每行图标数和开机自启;支持导入 / 导出配置及恢复默认参数
- **配置自动加载**:外部修改 `apps.json` 后自动生效;导入前自动备份,无效导入不会替换现有配置
- **开机自启**:安装到 `/Applications` 或 `~/Applications` 后,首次启动自动注册登录项(可在应用设置或系统设置中关闭)

## 要求

- macOS 13+,带刘海的 MacBook(依赖 `safeAreaInsets.top > 0` 探测刘海)

## 下载

不想自己编译:到 [Releases](https://github.com/BiBoyang/NotchLauncher/releases/latest) 下载 zip,解压得到 `NotchLauncher.app`,拖入 `/Applications` 或 `~/Applications` 直接打开。

应用已用 Developer ID 签名并通过 Apple 公证,Gatekeeper 直接放行。首次启动自动注册登录项,可在应用设置或 系统设置 → 通用 → 登录项与扩展 中关闭。

## 配置

配置文件:`~/Library/Application Support/NotchLauncher/apps.json`(首次运行自动创建)。

UI 操作(拖入/拖出/拖动排序/右键菜单)会自动写回该文件;也可以右键 →「编辑配置文件」手工编辑,格式:

```json
{
  "settings": {
    "openDelay": 0.15,
    "closeDelay": 0.35,
    "iconsPerRow": 8,
    "loginItemEnabled": true
  },
  "apps": [
    { "name": "Safari", "bundleID": "com.apple.Safari" }
  ]
}
```

- `apps` 数组的顺序就是面板上图标的显示顺序
- 条目身份:bundleID 优先,无 bundleID 用 path;可选 `hidden: true` 隐藏条目
- 外部修改保存后自动加载;面板菜单中的「重新加载」仍可手动使用
- `settings` 整个节点可省略,省略或字段非法时回退默认值(逐字段容错,单字段写错不影响其它配置)
- 延迟范围 0–2 秒,每行图标数范围 3–10;通常直接用右键 →「设置…」图形化调整即可
- 最多添加 16 个可见应用;隐藏条目不占名额,但满员时不能恢复隐藏
- `loginItemEnabled: false` 表示不再自动注册登录项;恢复默认参数会保留该选择
- 设置窗口可导入 / 导出完整配置;导入前备份到 `~/Library/Application Support/NotchLauncher/Backups/`

## 构建与安装

```bash
swift build                # 调试构建
./scripts/build-app.sh     # release 构建并打包到 build/NotchLauncher.app
open build/NotchLauncher.app
```

## 冒烟测试

无人值守几何回归(运行时鼠标会被 warp 几秒,期间请勿触碰;结束时自动恢复配置并重启日常实例):

```bash
scripts/smoke.sh
```

一条命令完成:构建 debug 版 → 用四组夹具替换 `apps.json` → warp 触发面板展开 → 从系统窗口服务器(CGWindowList)读面板真实 bounds 断言(1 app 325×152、显式 6 列的 7 app 590×254、每行 3 个时两行高度 325×254、默认 8 列的 100 app 778×254,均相对刘海居中、窗口 layer 33)→ 恢复配置并重启日常实例。全 PASS exit 0,任一 FAIL exit 1。几何断言不需要辅助功能/屏幕录制权限。

数据层(配置读写、reorder、settings 容错、导入备份、隐藏、16 个可见应用上限、文件监控)的自动断言,不接管鼠标:

```bash
swiftc Sources/NotchLauncher/AppConfig.swift Sources/NotchLauncher/ConfigFileMonitor.swift \
  scripts/verify-config.swift -o /tmp/nl-verify-config && /tmp/nl-verify-config
```

手动观察开合行为(应用运行中):

```bash
swift scripts/smoke-warp.swift
```

脚本把鼠标 warp 到刘海再移回,观察 stderr 日志出现 `open` / `closed` 即正常。

## English

A macOS launcher that lives in the notch — hover the notch to reveal a panel, click an icon to launch or activate the app.

- Icons keep a fixed order (the config array order) and never reshuffle when apps launch or quit; running apps are full-color with a dot, idle apps dimmed
- Grid layout: 8 icons per row by default (3–10 configurable), at most 2 visible rows, with scrolling for overflow
- Add up to 16 visible apps; existing over-limit configs are preserved and remain scrollable
- Add apps: drag a `.app` onto the notch, the panel expands, drop to add (name/bundleID detected automatically, duplicates skipped)
- Reorder apps by dragging an icon inside the panel — siblings move aside live, drop writes the new order back
- Remove apps: drag an icon out of the panel (more than 24pt past the edge) and release; drops inside the panel and small drags bounce back harmlessly
- Right-click an icon: open / quit / force quit (when running) / reveal in Finder / hide / remove from panel
- Right-click the panel: add apps, Settings…, restore hidden apps, edit config, reload, quit
- Settings: tune hover delays, icons per row and launch at login; import/export config or reset interaction defaults
- External config edits reload automatically; imports are validated and the previous config is backed up first
- Auto-registers as a login item when installed under `/Applications` or `~/Applications` (toggle in app or System Settings)
- Optional `settings` (`openDelay`, `closeDelay`, `iconsPerRow`, `loginItemEnabled`) and per-app `hidden`; tolerant decoding with defaults and clamping
- Requires macOS 13+ and a MacBook with a notch
- Download the signed & notarized build from [Releases](https://github.com/BiBoyang/NotchLauncher/releases/latest), or build it yourself with `swift build` / `./scripts/build-app.sh`

## License

[MIT](LICENSE)
