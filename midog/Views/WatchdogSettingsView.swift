import SwiftUI

struct WatchdogSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var draft = ""
    @State private var status = "正在查询…"
    @State private var busy = false
    @State private var installed = WatchdogService.installed
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("第三方代理监控")
                Spacer()
                MiniButton(title: "刷新状态", disabled: busy) {
                    Task { await refresh() }
                }
                if installed {
                    MiniButton(title: "卸载监控", disabled: busy) { apply(uninstall: true) }
                }
                MiniButton(title: busy ? "处理中…" : (installed ? "保存并更新" : "启用监控"),
                           disabled: busy || !loaded) { apply(uninstall: false) }
            }
            Text(status).font(.system(size: 12.5)).foregroundStyle(T.fg)
            Text("独立轻量进程，由系统开机启动和自动恢复；退出 midog 或停止内核后仍生效。命中的代理先正常退出，3 秒后仍存活则强制结束。启用和修改需管理员授权。")
                .font(.system(size: 11)).foregroundStyle(T.muted)
            Text("每行一个完整可执行文件路径，# 开头为注释，不支持通配符。请核对本机路径；同时列入客户端和其内核可处理自动拉起。")
                .font(.system(size: 11)).foregroundStyle(T.muted)
            TextEditor(text: $draft)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 150)
                .background(Color(hex: 0x0E1418))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task {
            if !loaded {
                do { draft = try WatchdogService.rules(); loaded = true }
                catch { store.toast(error.localizedDescription, error: true) }
            }
            await refresh()
        }
    }

    private func refresh() async {
        status = await Task.detached { WatchdogService.status() }.value
        installed = WatchdogService.installed
    }

    private func apply(uninstall: Bool) {
        busy = true
        let rules = draft
        Task {
            defer { busy = false }
            do {
                try await Task.detached {
                    if uninstall { try WatchdogService.uninstall() }
                    else { try WatchdogService.install(rules: rules) }
                }.value
                store.toast(uninstall ? "已卸载独立监控" : "已安装并加载独立监控")
            } catch { store.toast(error.localizedDescription, error: true) }
            await refresh()
        }
    }
}
