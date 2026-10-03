import Foundation
import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var settingsDraft = ""
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                kernelCard
                filterCard
                tunCard
                egressSplitCard
                settingsJSONCard
                dataCard
            }
            .padding(18)
        }
        .onAppear {
            if !loaded {
                settingsDraft = store.settingsJSONText
                loaded = true
            }
        }
    }

    // ---- 内核 ----

    private var kernelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("内核")
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("midog 内核")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(T.fg)
                    Text("应用内置，首次运行时释放到 \(store.kernelPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(T.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            Rectangle().fill(T.line.opacity(0.6)).frame(height: 1)

            Text("首次启动需管理员授权注册 launchd 服务；之后系统会按相同参数自动重启内核，退出 midog 不会停止服务。")
                .font(.system(size: 11))
                .foregroundStyle(T.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // ---- TUN 提权 ----

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("系统内容过滤")
                Spacer()
                MiniButton(title: store.contentFilterBusy ? "授权中…" : "授权 / 重试",
                           disabled: store.contentFilterBusy) {
                    ContentFilterInstaller.shared.install()
                }
            }
            Text(store.contentFilterStatus)
                .font(.system(size: 12.5))
                .foregroundStyle(T.fg)
            Text("独立拦截内置成人域名；mihomo 继续处理代理和分流规则。首次启用需在系统设置中批准。")
                .font(.system(size: 11))
                .foregroundStyle(T.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var tunCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("TUN 权限")
            HStack(spacing: 8) {
                StatusDot(on: store.privileged, onColor: T.ok)
                Text(store.privileged
                     ? "launchd 系统服务以 root 运行，可开关 TUN"
                     : "启动内核时授权安装 launchd 系统服务，即可使用 TUN")
                    .font(.system(size: 12.5))
                    .foregroundStyle(store.privileged ? T.fg : T.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // ---- 出口分流 ----

    private var egressSplitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("出口分流 · 代理走 USB / 直连走 Wi-Fi")
                Spacer()
                if store.egressSplitOn {
                    MiniButton(title: store.egressTesting ? "测试中…" : "测试出口",
                               disabled: store.egressTesting) {
                        Task { await store.testEgressSplit() }
                    }
                    MiniButton(title: "关闭分流") {
                        Task { await store.toggleEgressSplit() }
                    }
                } else {
                    AccentButton(title: "开启分流") {
                        Task { await store.toggleEgressSplit() }
                    }
                }
            }

            Text("把代理节点固定绑到 iPhone USB 网卡拨号，直连流量固定走 Wi-Fi。开启时现场探测网卡编号并锁定。")
                .font(.system(size: 11))
                .foregroundStyle(T.muted)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(T.line.opacity(0.6)).frame(height: 1)

            if let split = store.egressSplit {
                egressRow(role: "代理出口",
                          label: split.proxyLabel,
                          ip: store.splitProxyIP,
                          missingHint: "网卡已断开")
                egressRow(role: "直连出口",
                          label: split.directLabel,
                          ip: store.splitDirectIP,
                          missingHint: "网卡已断开")

                if store.egressSplitDegraded {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(T.bad)
                        Text("\(split.proxyLabel) 已经掉线，所有代理节点都会连接失败。分流不会自动切回 Wi-Fi —— 请重新插上手机，或点右上角「关闭分流」。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(T.bad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(T.bad.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Text("拔掉手机后不会自动切换：代理会全部失败，需要手动关闭分流。")
                        .font(.system(size: 11))
                        .foregroundStyle(T.muted)
                }

                if !store.egressChecks.isEmpty {
                    Rectangle().fill(T.line.opacity(0.6)).frame(height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.egressChecks) { check in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: checkIcon(check.state))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(checkColor(check.state))
                                    .frame(width: 12)
                                Text(check.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(T.fg)
                                    .frame(width: 108, alignment: .leading)
                                Text(check.detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(check.state == .pass ? T.muted : checkColor(check.state))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            } else {
                egressRow(role: "代理出口",
                          label: store.detectedUSB?.label ?? "未检测到 USB 网卡",
                          ip: store.detectedUSB?.ipv4,
                          missingHint: store.detectedUSB == nil
                            ? "用数据线连接 iPhone，并打开「个人热点 → 允许其他人加入」"
                            : "没有取得 IP：系统设置 → 网络 → 该网卡 → 详细信息，关闭「除非需要，否则停用」")
                egressRow(role: "直连出口",
                          label: store.detectedWiFi?.label ?? "未检测到 Wi-Fi 网卡",
                          ip: store.detectedWiFi?.ipv4,
                          missingHint: "请先连上 Wi-Fi")
                Text("当前未开启：全部出站由内核按系统默认路由处理。")
                    .font(.system(size: 11))
                    .foregroundStyle(T.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func checkIcon(_ state: EgressCheck.State) -> String {
        switch state {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        }
    }

    private func checkColor(_ state: EgressCheck.State) -> Color {
        switch state {
        case .pass: return T.ok
        case .warn: return T.warn
        case .fail: return T.bad
        }
    }

    private func egressRow(role: String, label: String, ip: String?, missingHint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(role)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(T.muted)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    StatusDot(on: ip != nil, onColor: T.ok)
                    Text(label)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(ip != nil ? T.fg : T.warn)
                }
                Text(ip ?? missingHint)
                    .font(.system(size: 11, design: ip != nil ? .monospaced : .default))
                    .foregroundStyle(T.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // ---- 系统配置 JSON ----

    private var settingsJSONCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("系统配置 · settings / dns / hosts")
                Spacer()
                MiniButton(title: "重新载入") {
                    settingsDraft = store.settingsJSONText
                    store.toast("已重新载入当前配置")
                }
                AccentButton(title: "保存并应用") {
                    Task {
                        if await store.saveSettingsJSON(settingsDraft) {
                            settingsDraft = store.settingsJSONText
                        }
                    }
                }
            }
            Text("内核系统配置（端口 / DNS / hosts 等），JSON 格式。保存后自动热重载，不重启内核。")
                .font(.system(size: 11))
                .foregroundStyle(T.muted)

            TextEditor(text: $settingsDraft)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(T.fg)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 240)
                .background(Color(hex: 0x0E1418))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // ---- 数据 ----

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("数据")
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("数据目录")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(T.fg)
                    Text(AppPaths.dataDir.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(T.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                MiniButton(title: "在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.dataDir])
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
