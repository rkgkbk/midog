# 内置代理识别目录

核对日期：2026-10-04。此目录针对 macOS 可运行的代理客户端及独立内核，不声称覆盖 GitHub 的全部项目或全部版本。

2026-11-04 补充 Proxifier 3.15.0：从本机安装包的主程序及内嵌系统扩展 `Info.plist` 核实 `com.initex.proxifier.v3.macos` 和 `com.initex.proxifier.v3.macos.ProxifierExtension`，签名 Team 为 `NXELXU5YLW`，通过 `codesign --verify --deep --strict` 检查。发行来源：[Proxifier 官方下载](https://www.proxifier.com/download/index.html)。两条 Bundle 规则同时覆盖原名及改名后的应用/扩展目录；未增加通用进程名规则。

规则定义在 `midogWatchdog/proxy_catalog.h`，同时编译进 watchdog 和系统内容过滤扩展，设置页只读。两者共用 `proxy_match.h` 的匹配逻辑。扩展在新连接上通过系统提供的应用 / 进程 audit token 解析可执行文件路径，命中后直接拒绝连接，不依赖 watchdog 是否运行，也不依赖连接是否带有域名。watchdog 仍负责结束代理进程。

更新需要安装并批准新版系统扩展；仅更新 watchdog 不会更新过滤扩展。过滤扩展本身必须保持启用。此检查针对新连接，不承诺接管更新前已经放行的连接；无法解析进程身份时仍继续原有域名过滤，不全局断网。应用 Bundle ID 与可执行文件名为精确匹配（区分大小写），不匹配安装目录，也不做名称子串匹配。Bundle ID 来自外层或嵌套应用、系统扩展的 Info.plist，因此移动或改名 App 仍可识别。独立内核移动目录后文件名不变也能识别。

这些是身份线索，不是第三方签名验证。未收录项目、修改 Bundle ID 且重命名可执行文件的程序、脚本解释器承载的代理不保证识别。相同文件名的非代理自编译程序也会命中；因此不纳入 `core`、`client`、`node`、`python`、`ssh`、`curl` 等通用名称，也不把所有浏览器或 VPN 一并终止。系统受保护的进程可能无法终止，守护程序会记录失败。管理员仍能替换或卸载本服务。

## 已核对项目与来源

每条规则的上游证据来自项目本身的构建、打包配置或命令定义，以下链接可供复查。部分旧项目已归档；未确认的规则不加入。`sing-box for Apple` 的 Bundle ID 由 `BASE_PACKAGE_IDENTIFIER` 和目标后缀组合得到。ClashX 条目覆盖使用相同身份的 Meta 版本；不推断所有 fork 均相同。

| 项目 | 精确可执行文件名 | Bundle ID | 上游证据 |
| --- | --- | --- | --- |
| Clash Verge Rev | `verge-mihomo`, `verge-mihomo-alpha` | `io.github.clash-verge-rev.clash-verge-rev` | [源码](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src-tauri/tauri.conf.json) |
| Clash Verge Rev | `clash-verge` | — | [源码](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src-tauri/Cargo.toml) |
| Clash Verge Service | `clash-verge-service` | — | [源码](https://github.com/clash-verge-rev/clash-verge-service/blob/main/Cargo.toml) |
| Clash Verge (legacy) | — | `top.gydi.clashverge` | [源码](https://github.com/zzzgydi/clash-verge/blob/main/src-tauri/tauri.conf.json) |
| ClashX / ClashX.Meta | `ClashX` | `com.west2online.ClashX` | [源码](https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX.xcodeproj/project.pbxproj) |
| Clash Nyanpasu | `clash`, `mihomo-alpha`, `clash-rs`, `clash-rs-alpha`, `nyanpasu-service` | `moe.elaina.clash.nyanpasu` | [源码](https://github.com/libnyanpasu/clash-nyanpasu/blob/main/backend/tauri/tauri.conf.json) |
| Clash Nyanpasu | `clash-nyanpasu` | — | [源码](https://github.com/libnyanpasu/clash-nyanpasu/blob/main/backend/tauri/Cargo.toml) |
| Clash Party / Mihomo Party | `Mihomo Party` | `party.mihomo.app` | [源码](https://github.com/mihomo-party-org/clash-party/blob/main/electron-builder.yml) |
| Clash Party / Mihomo Party | `Clash Party` | — | [源码](https://github.com/mihomo-party-org/clash-party/blob/smart_core/electron-builder.yml) |
| ClashBar | `ClashBar` | — | [源码](https://github.com/Sitoi/ClashBar/blob/HEAD/Makefile) |
| Hiddify | `Hiddify` | `app.hiddify.com` | [源码](https://github.com/hiddify/hiddify-app/blob/main/macos/Runner/Configs/AppInfo.xcconfig) |
| FlClash | `FlClash` | `com.follow.clash` | [源码](https://github.com/chen08209/FlClash/blob/main/macos/Runner/Configs/AppInfo.xcconfig) |
| V2rayU | `V2rayU` | `net.yanue.V2rayU` | [源码](https://github.com/yanue/V2rayU/blob/master/V2rayU.xcodeproj/project.pbxproj) |
| V2RayX | `V2RayX` | `cenmrev.V2RayX` | [源码](https://github.com/Cenmrev/V2RayX/blob/master/V2RayX.xcodeproj/project.pbxproj) |
| v2rayN | `v2rayN` | — | [源码](https://github.com/2dust/v2rayN/blob/HEAD/v2rayN/v2rayN.Desktop/v2rayN.Desktop.csproj) |
| ShadowsocksX-NG | `ShadowsocksX-NG` | `com.qiuyuzhou.ShadowsocksX-NG` | [源码](https://github.com/shadowsocks/ShadowsocksX-NG/blob/develop/ShadowsocksX-NG.xcodeproj/project.pbxproj) |
| Throne | `Throne` | — | [源码](https://github.com/throneproj/Throne/blob/dev/CMakeLists.txt) |
| GUI.for.Clash | `GUI.for.Clash` | — | [源码](https://github.com/GUI-for-Cores/GUI.for.Clash/blob/HEAD/wails.json) |
| GUI.for.SingBox | `GUI.for.SingBox` | — | [源码](https://github.com/GUI-for-Cores/GUI.for.SingBox/blob/HEAD/wails.json) |
| Oblivion Desktop | `oblivion-desktop` | `org.desktop.oblivion` | [源码](https://github.com/bepass-org/oblivion-desktop/blob/HEAD/package.json) |
| sing-box for Apple | — | `io.nekohasekai.sfamt`, `io.nekohasekai.sfamt.standalone`, `io.nekohasekai.sfamt.system`, `io.nekohasekai.sfamt.macapp`, `io.nekohasekai.sfamt.application` | [源码](https://github.com/SagerNet/sing-box-for-apple/blob/HEAD/sing-box.xcodeproj/project.pbxproj) |
| Mihomo | `mihomo` | — | [源码](https://github.com/MetaCubeX/mihomo/blob/Meta/Makefile) |
| sing-box | `sing-box` | — | [源码](https://github.com/SagerNet/sing-box/blob/HEAD/Makefile) |
| Xray-core | `xray` | — | [源码](https://github.com/XTLS/Xray-core/blob/main/.github/workflows/release.yml) |
| V2Ray-core | `v2ray` | — | [源码](https://github.com/v2fly/v2ray-core/blob/master/.github/workflows/release.yml) |
| v2rayA | `v2raya`, `v2raya_core` | — | [源码](https://github.com/v2rayA/v2rayA/blob/HEAD/.github/workflows/_release.yml) |
| Hysteria | `hysteria` | — | [源码](https://github.com/apernet/hysteria/blob/master/app/cmd/root.go) |
| Shadowsocks Rust | `sslocal`, `ssservice` | — | [源码](https://github.com/shadowsocks/shadowsocks-rust/blob/master/Cargo.toml) |
| Shadowsocks libev | `ss-local`, `ss-tunnel` | — | [源码](https://github.com/shadowsocks/shadowsocks-libev/blob/HEAD/src/CMakeLists.txt) |
| Trojan | `trojan` | — | [源码](https://github.com/trojan-gfw/trojan/blob/master/CMakeLists.txt) |
| Trojan-Go | `trojan-go` | — | [源码](https://github.com/p4gefau1t/trojan-go/blob/HEAD/Makefile) |
| Juicity | `juicity-client` | — | [源码](https://github.com/juicity/juicity/blob/main/Makefile) |
| Mieru | `mieru` | — | [源码](https://github.com/enfein/mieru/blob/main/Makefile) |
| tun2socks | `tun2socks` | — | [源码](https://github.com/xjasonlyu/tun2socks/blob/main/Makefile) |
| Brook | `brook` | — | [源码](https://github.com/txthinking/brook/blob/master/cli/brook/main.go) |
| GOST | `gost` | — | [源码](https://github.com/go-gost/gost/blob/master/README.md) |

## 上版兼容项

另保留 `ClashX Pro`、`Surge`、`Shadowrocket` 三个精确可执行文件名，来源为本仓库提交 `b7e5e48` 的 `midog/Resources/proxies.list`。它们沿用上版覆盖范围，不计入本次核对的 33 组 GitHub 项目，也没有在本次新增未经核对的 Bundle ID。加上 Proxifier 后总计 63 条规则。可通过 `git show b7e5e48:midog/Resources/proxies.list` 追溯。

## 维护方法

### 应用内监控

midog 启动时运行随 App 打包的 `midog-watchdog --user-monitor`，与独立系统服务共用目录及 TERM/KILL 逻辑。每 3 秒检查当前用户的代理进程；关闭主窗口不停止，正常退出 App 会终止子进程，App 被强制结束后子进程检测到父进程消失也会退出。应用每 3 秒检查子进程、异常退出后重新启动，并查询独立系统 watchdog 状态。总览在系统监控未运行时显示警告及应用内兜底状态，设置页分别显示两层状态。

应用内监控不注册新的开机后台项，不更改系统后台开关，不需要管理员授权，只能结束当前用户进程。独立 watchdog 后台项关闭时，只要 midog 仍运行，就有应用内兜底；退出 midog 且系统 watchdog 未运行后，不再有进程终止层，仍启用的网络扩展继续限制连接。root/其他用户进程不属于应用内监控覆盖范围。

### 本机扩展更新与实测（2026-11-04）

发现 App 内嵌扩展与系统安装扩展的临时签名哈希不同，但构建号均为 6。系统日志报告 `Rejecting agent com.xx.midog because it does not satisfy the code signature requirements`，过滤服务未启动，即使扩展开关已开启也不会拦截。构建号升级为 7，并在扩展激活完成后创建新的 `NEFilterProviderConfiguration`、保存过滤配置；本机更新后开始收到连接。

验证时 watchdog 服务未加载，FlClash 及 FlClashCore 保持运行：通过 FlClash 的 `127.0.0.1:7890` 请求 `https://example.com` 和 `https://www.apple.com` 均未完成 TLS（curl 35、HTTP 000）；同样请求通过 midog 的 `127.0.0.1:7891` 均返回 HTTP 200。相同临时 TCP 测试程序以普通名称运行可连接 `1.1.1.1:443`，复制为名单中的 `FlClash` 名称后连接失败。测试未切换 FlClash 的 TUN 或系统代理开关，不代表已验证所有代理或模式。网络扩展限制联网，不阻止应用启动或创建代理配置；应用退出由 watchdog 执行。

后续重新签名/发布时需递增 App 与扩展构建号，并完成系统扩展更新及过滤配置保存。`systemextensionsctl` 的 enabled 状态不能单独证明过滤服务已成功启动；应同时检查服务连通性及真实请求。

新增规则前确认上游 macOS 构建产物或 Bundle ID，在头文件和本页记录来源，执行 `python3 tests/WatchdogCheck.py`，再重新构建并发布。运行时没有下载名单或读取外部名单的入口。已安装服务需点击「更新监控」替换二进制，旧版 `proxies.list` 会在更新成功后删除。

以下为本次读取的来源文件 SHA-256，便于辨别链接内容后来是否改变；不是第三方应用的二进制哈希：

- https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src-tauri/tauri.conf.json — `4f2f064b423ea035f02f4ad9d61dc3b80f4bdc7c3e688693ddb311ebbf3bba3c`
- https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src-tauri/Cargo.toml — `b810cf224de9098f73ca0cc4c25b164864685139427fbc1046f4ee17d2ba695d`
- https://github.com/clash-verge-rev/clash-verge-service/blob/main/Cargo.toml — `8b6105ed3bc9f61c5b6f5c528ab704de7245e36cacb50d2cf37226b817c9143c`
- https://github.com/zzzgydi/clash-verge/blob/main/src-tauri/tauri.conf.json — `58e7dee76ed2ab3ae59c5958906ec2cac50bb6d47f59a16b9170c7d01f3d8377`
- https://github.com/MetaCubeX/ClashX.Meta/blob/master/ClashX.xcodeproj/project.pbxproj — `f3448b15f916fa1880128015020c8530344a78eb763f9081ce266f1f2e8ba971`
- https://github.com/libnyanpasu/clash-nyanpasu/blob/main/backend/tauri/tauri.conf.json — `79a7b792f175610e7275160a4b3383d83d6b4f3824acdc7c96bf3785bb7ff30c`
- https://github.com/libnyanpasu/clash-nyanpasu/blob/main/backend/tauri/Cargo.toml — `ca27c9efb820563b10e6780f57476807e5876a3bbed23709d0c72a6e2da8dd3b`
- https://github.com/mihomo-party-org/clash-party/blob/main/electron-builder.yml — `f78fd708970460bffffd6757286aed8d9cbce6a55306743d7dc663e02d115188`
- https://github.com/mihomo-party-org/clash-party/blob/smart_core/electron-builder.yml — `8c86249b2fdf9df6607fb35388419dc524f4859737ab9072708aa1038d8a6316`
- https://github.com/Sitoi/ClashBar/blob/HEAD/Makefile — `e53f006e9ac5052e82dbee66ac63d6dad213470ca3e0143b2814ee57e1e6f8c1`
- https://github.com/hiddify/hiddify-app/blob/main/macos/Runner/Configs/AppInfo.xcconfig — `817448489fcf3197180d1646c9f71ebb9a5ac38ccfad842d9933a55ce6877af3`
- https://github.com/chen08209/FlClash/blob/main/macos/Runner/Configs/AppInfo.xcconfig — `0bbafdb23fba60097c28bbb197a5f534282453684744a44b5eb505ef734c10ec`
- https://github.com/yanue/V2rayU/blob/master/V2rayU.xcodeproj/project.pbxproj — `e955bc6fc6972d692afed6bcc0526cec69fa9be07073c5fb4c0840965d1eea45`
- https://github.com/Cenmrev/V2RayX/blob/master/V2RayX.xcodeproj/project.pbxproj — `0fbc7aa10f648f48061dce606533af9168ae1d40504d5b079ee9ddf3a82edc13`
- https://github.com/2dust/v2rayN/blob/HEAD/v2rayN/v2rayN.Desktop/v2rayN.Desktop.csproj — `07e001c86243e5b6ec01b28b0527fe92d25defecb9394e3386ff88a63a0b34de`
- https://github.com/shadowsocks/ShadowsocksX-NG/blob/develop/ShadowsocksX-NG.xcodeproj/project.pbxproj — `935fa78a1df2202e4ef7da7ad6e04e3deca5dcb96fe56589b842a5b16e20f79c`
- https://github.com/throneproj/Throne/blob/dev/CMakeLists.txt — `b624f363ced22ebf60b782cc71374122289813ad7ccf7bce342505c98f099fe0`
- https://github.com/GUI-for-Cores/GUI.for.Clash/blob/HEAD/wails.json — `e3b593ee04b8e9b5c769b05879c85ca100510505eb666217cf6cffb92b6b83f1`
- https://github.com/GUI-for-Cores/GUI.for.SingBox/blob/HEAD/wails.json — `abe9c152eb4c50c3dc427ccfe359fae3f8e7f2fc278f2d8f74d0cefbdb515ad0`
- https://github.com/bepass-org/oblivion-desktop/blob/HEAD/package.json — `626dfb43cc588d22552fcc9e510fd4e151051fbf822d12606b1b357549ff1653`
- https://github.com/SagerNet/sing-box-for-apple/blob/HEAD/sing-box.xcodeproj/project.pbxproj — `ade56eb920b839d9883153edc1ea5812a3482b177de31652c1075b812bfc87df`
- https://github.com/MetaCubeX/mihomo/blob/Meta/Makefile — `794e9972af319e97851a36ddafe83e0a0fd08671e5f27529610ffde351a9b0cf`
- https://github.com/SagerNet/sing-box/blob/HEAD/Makefile — `eaa084326aff256b5529e74aa77513140a6ffb1b455fabb78b5361f52ebbb6c5`
- https://github.com/XTLS/Xray-core/blob/main/.github/workflows/release.yml — `0d1b6982851085332a7c1c24c05a195a818bf74ebe040119bbc96f91ea35f497`
- https://github.com/v2fly/v2ray-core/blob/master/.github/workflows/release.yml — `c34f62b09780337d70f5ff2dc0cdcb88b44ac56690fffb8f3f7b875882d8f8c5`
- https://github.com/v2rayA/v2rayA/blob/HEAD/.github/workflows/_release.yml — `99efcbd960efec6a932312e14b86f37d3040a3702a51b62429836278f5c54970`
- https://github.com/apernet/hysteria/blob/master/app/cmd/root.go — `b82ab08cba60ee57d4e1e6cb56f6283a922731a8bef5f5937467fc873970f379`
- https://github.com/shadowsocks/shadowsocks-rust/blob/master/Cargo.toml — `3a99344b7271fba1a2b725ca2392e786c215fd858b38d53ec5fb52652957d4c0`
- https://github.com/shadowsocks/shadowsocks-libev/blob/HEAD/src/CMakeLists.txt — `d0f7a1bb61993900996913c6792a51f6137f9c488dee6ee94623f159f85b5e0b`
- https://github.com/trojan-gfw/trojan/blob/master/CMakeLists.txt — `0021f2b6faa7cd6b444981a07b775717b2295e79cdb12779e8405d8655ee8834`
- https://github.com/p4gefau1t/trojan-go/blob/HEAD/Makefile — `88b170dfa217a3faebde310d3c586bed8c497f23ff9e057819f774c75078c38a`
- https://github.com/juicity/juicity/blob/main/Makefile — `1360739a4d34c16ad0b5acaa99a234e6489bc8f8491141f471832ffaa350ca1f`
- https://github.com/enfein/mieru/blob/main/Makefile — `cbcd67425507c502fe2ba8d2e9f3c695d096f1d20dbbcc078a2749a5c57931e2`
- https://github.com/xjasonlyu/tun2socks/blob/main/Makefile — `216388d585100acb4376f3578a6bb67d12913c252ae258495091dae88652c58a`
- https://github.com/txthinking/brook/blob/master/cli/brook/main.go — `d1dc326504f7feb9b735794581190b9e37f5d721149c856cbc702859d5fd15ef`
- https://github.com/go-gost/gost/blob/master/README.md — `2a1c805fcdcf8908cf2a1ac0e3aaeb1aa521ac8bf63b2b37b3cd737821274456`
