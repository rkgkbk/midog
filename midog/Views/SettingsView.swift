import Foundation
import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var focus = FocusStore.shared
    @State private var settingsDraft = ""
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                kernelCard
                filterCard
                FocusSettingsView()
                WatchdogSettingsView()
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
                    Text("midog-core")
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
            if focus.needsProxyUpgrade {
                Text("已有代理服务需要更新，才能读取专注屏蔽规则。更新会请求管理员授权并重启代理内核。")
                    .font(.system(size: 11)).foregroundStyle(T.warn)
                MiniButton(title: "更新代理支持") {
                    Task {
                        guard !store.busy else { return }
                        await store.restartCore()
                        await focus.refresh()
                    }
                }.disabled(store.busy || focus.busy)
            }
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
                MiniButton(title: store.contentFilterBusy ? "正在配置…" : "安装 / 更新 / 重试",
                           disabled: store.contentFilterBusy) {
                    ContentFilterInstaller.shared.install()
                }
            }
            Text(store.contentFilterStatus)
                .font(.system(size: 12.5))
                .foregroundStyle(T.fg)
            Text(focus.available ? "专注服务已连接" : "专注服务未连接")
                .font(.system(size: 12)).foregroundStyle(focus.available ? T.accent : T.warn)
            if let error = focus.error {
                Text(error).font(.system(size: 12)).foregroundStyle(T.warn).textSelection(.enabled)
            }
            if !focus.proxyStatus.isEmpty {
                Text(focus.proxyStatus).font(.system(size: 11)).foregroundStyle(T.muted)
            }
            Text("内置成人域名拦截和专注网站屏蔽共用此扩展。首次启用需在系统设置中批准。")
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
