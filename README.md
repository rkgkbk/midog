<div align="center">

# midog

**简单易用、界面美观的 macOS 原生代理客户端**

基于 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash Meta）内核 · SwiftUI 原生开发 · 零第三方依赖

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue?logo=apple)](#系统要求)
[![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-purple)](https://developer.apple.com/xcode/swiftui/)
[![Kernel](https://img.shields.io/badge/kernel-mihomo-green)](https://github.com/MetaCubeX/mihomo)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

<img src="docs/screenshot.png" width="800" alt="midog 总览界面">

</div>

---

## 为什么选择 midog

- **⚡ 简单易用** — 添加订阅、选节点、开代理，三步完成。规则、订阅、内核配置都有清晰的图形界面，也保留纯文本入口给进阶用户。
- **🍎 macOS 原生** — 纯 SwiftUI + AppKit 编写，不是 Electron / Web 套壳。启动快、内存占用小、跟手流畅，完美适配深色模式与系统菜单栏。
- **🎨 界面美观** — 精心设计的深色仪表盘：实时上下行速率曲线、活跃连接数、当前路由链路、内核日志一屏尽览。
- **📦 开箱即用** — 基于 mihomo 的 `midog-core` 内核内置于应用包内，首次运行自动释放，无需手动下载或配置内核。
- **🪶 零依赖** — 不引入任何第三方 Swift 包，代码轻量透明，易于审计和二次开发。

## 功能特性

| 模块 | 说明 |
| --- | --- |
| **总览** | 实时流量曲线、活跃连接、当前节点延迟、路由链路、滚动日志；一键切换 规则 / 全局 / 直连 模式，随时启停内核 |
| **节点** | 节点分组浏览、批量延迟测速、一键切换；支持 provider 内节点测速 |
| **节点来源** | 多订阅共存，每个来源作为独立 proxy-provider 注入内核；订阅更新只刷新对应 provider，**不打断现有连接**；支持导入本地 Clash YAML |
| **分流规则** | 手写规则逐行编辑（支持注释），支持远程规则集（GitHub / CDN）和本地规则集导入，base64、gfwlist 等格式自动转换 |
| **日志** | 内核日志实时流式展示，按级别高亮 |
| **设置** | 内核 JSON 配置（端口 / DNS / hosts 等）保存后**热重载不重启**；launchd 自动重启内核；TUN 由系统服务提供权限 |
| **菜单栏** | 常驻状态栏图标，关窗不退出，随时唤起主窗口 |

### 系统内容过滤

macOS 版同时把内置 `category-porn.list` 打进内容过滤系统扩展。扩展按域名阻断可识别的连接；midog-core 仍使用同一规则文件处理代理和 TUN 流量。退出 App 或内核不会主动关闭已启用的系统扩展。

正式发布时需给 App 和 `midogFilter` target 配置同一个 Apple Developer Team、签名，并把签名后的 App 安装到 `/Applications`。首次启动要在系统设置中批准系统扩展和内容过滤。Debug 使用开发签名权限，Release 使用 Developer ID 系统扩展权限；发布包还需公证。未签名构建只能用于编译检查，不能安装系统扩展。扩展目前使用随 App 发布的规则快照，更新列表需发布新版 App。过滤器无法从每条网络连接取得域名，代理流量仍由 midog-core 规则兜底。

仅在已关闭 SIP 的本机开发环境，可运行 `scripts/build-local-filter.sh` 生成临时签名的测试 App；这只验证构建和签名，不保证 NetworkExtension 接受未获授权的权限，也不能用于发布。开启系统扩展开发模式可跳过 App 必须位于「应用程序」目录的检查：`systemextensionsctl developer on`。测试结束后应恢复 SIP。

## 系统要求

- macOS 15 (Sequoia) 或更高版本
- Apple Silicon / Intel

## 安装

### 下载安装

从 [Releases](../../releases) 页面下载最新的 `midog.app`，拖入「应用程序」文件夹即可。首次启动内核时会请求管理员授权，安装 root 管理的 launchd 服务。

### 从源码构建

```bash
git clone https://github.com/<your-name>/midog.git
cd midog
open midog.xcodeproj
```

在 Xcode 中选择 `midog` scheme，`⌘R` 运行即可。内核已以 gzip 形式内置在 `midog/Resources/midog-core.gz`，无需额外准备。

## 快速上手

1. 打开 midog，进入 **节点来源**，粘贴你的 Clash 订阅链接（或导入本地 YAML）
2. 回到 **总览**，点击启动内核，打开代理开关
3. 在 **节点** 页测速并选择合适的节点，完成 ✅

> **TUN 模式**：内核通过 launchd 系统服务以 root 运行，无需再设置 setuid。停止内核会注销服务；再次启动需要管理员授权。

## 技术架构

```
midog/
├── Core/                  # 无 UI 的核心逻辑
│   ├── CoreService.swift        # launchd 内核服务
│   ├── KernelInstaller.swift    # 内置内核释放
│   ├── ControllerClient.swift   # mihomo RESTful API 客户端（节点/测速/连接）
│   ├── ConfigGenerator.swift    # 生成内核运行配置
│   ├── SubscriptionParser.swift # 订阅下载与 Clash YAML 校验
│   ├── RulesetParser.swift      # 远程规则集解析（base64 / gfwlist …）
│   └── Store.swift              # 应用状态中心
├── Views/                 # SwiftUI 界面
│   ├── DashboardView / NodesView / RulesView
│   ├── SourcesView / LogsView / SettingsView
│   └── Components / Theme       # 自绘组件与主题
└── Resources/midog-core.gz    # 内置 mihomo 内核
```

设计要点：

- **内核由 launchd 管理**：服务使用 `-d` 指向应用数据目录，异常退出自动重启；midog 通过 REST API 通信，退出 App 不结束内核
- **热更新优先**：订阅刷新走 provider 级更新、内核配置改动走热重载，尽量不打断已有连接
- **状态持久化**：节点选择、fake-ip 缓存等由内核 profile 持久化，重启后保持上次状态

## 常见问题

**订阅提示"需要 Clash 格式 YAML"？**
midog 使用 Clash 配置格式，暂不支持 V2Ray 通用节点链接（`vmess://` 等）订阅。请在机场后台选择 Clash / Clash Meta 订阅链接。

**开启 TUN 后没有生效？**
首次启动时授权安装 launchd 服务；如果 TUN 未生效，在总览页重启内核并检查系统日志。

**数据存储在哪里？**
配置、规则（`rules.txt`）、订阅缓存与释放后的内核统一存放在应用数据目录，可在 **设置 → 数据目录** 中直接打开。

## 参与贡献

欢迎 Issue 和 Pull Request！

1. Fork 本仓库并创建特性分支
2. 保持零第三方依赖的原则，代码风格与现有代码一致
3. 提交 PR 并描述改动动机

## 致谢

- [mihomo (Clash Meta)](https://github.com/MetaCubeX/mihomo) — 强大的代理内核
- 所有维护公开分流规则集的社区贡献者

## 许可证

本项目基于 [MIT License](LICENSE) 开源。

内置的 mihomo 内核遵循其自身的 [GPL-3.0 协议](https://github.com/MetaCubeX/mihomo/blob/Meta/LICENSE)。

---

<div align="center">

**midog** — 让 macOS 上的代理管理变得简单而优雅 🐕

如果这个项目对你有帮助，欢迎点一个 ⭐️

</div>
