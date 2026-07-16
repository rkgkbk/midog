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
                tunCard
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
                    Text("mihomo 内核路径")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(T.fg)
                    Text(store.kernelPath.isEmpty ? "未设置" : store.kernelPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(store.kernelPath.isEmpty ? T.warn : T.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                MiniButton(title: "选择…") { pickKernel() }
            }

            Rectangle().fill(T.line.opacity(0.6)).frame(height: 1)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("随应用启动内核")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(T.fg)
                    Text("打开 App 时自动启动 mihomo（存在已启用的节点来源时）")
                        .font(.system(size: 11))
                        .foregroundStyle(T.muted)
                }
                Spacer()
                Toggle("", isOn: $store.autoStart)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(T.accent)
                    .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // ---- TUN 提权 ----

    private var tunCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("TUN 权限")
            HStack(spacing: 8) {
                StatusDot(on: store.privileged, onColor: T.ok)
                Text(store.privileged
                     ? "内核已提权 (root + setuid)，可随时开关 TUN"
                     : "内核未提权：开启 TUN（接管系统流量）需要 root 权限创建虚拟网卡，仅需设置一次")
                    .font(.system(size: 12.5))
                    .foregroundStyle(store.privileged ? T.fg : T.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.privileged {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 在终端执行以下命令给内核提权；2. 回到顶部「重启」内核一次，之后即可随时开关 TUN。")
                        .font(.system(size: 11))
                        .foregroundStyle(T.muted)
                    HStack(spacing: 8) {
                        Text(store.tunSetupCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(T.accent)
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: 0x0E1418))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .textSelection(.enabled)
                        MiniButton(title: "复制命令") {
                            store.copyToPasteboard(store.tunSetupCommand)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
            Text("mihomo 系统配置（端口 / DNS / hosts 等），JSON 格式。保存后自动热重载，不重启内核。")
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

            Rectangle().fill(T.line.opacity(0.6)).frame(height: 1)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("从旧版导入数据")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(T.fg)
                    Text("选择旧版 Node 项目的 data 目录，导入 data.json / rules.txt / 订阅配置 / 规则缓存 / geo 数据库")
                        .font(.system(size: 11))
                        .foregroundStyle(T.muted)
                }
                Spacer()
                MiniButton(title: "选择目录…") { pickLegacyDir() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // ---- 选择器 ----

    private func pickKernel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "选择 mihomo 可执行文件"
        if panel.runModal() == .OK, let url = panel.url {
            store.kernelPath = url.path
            store.privileged = Store.binaryPrivileged(url.path)
            store.toast("内核路径已更新")
        }
    }

    private func pickLegacyDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择旧版项目的 data 目录（包含 data.json）"
        if panel.runModal() == .OK, let url = panel.url {
            store.importLegacyData(from: url)
        }
    }
}
