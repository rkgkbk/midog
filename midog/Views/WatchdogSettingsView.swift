import SwiftUI

struct WatchdogSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var catalog = ""
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
                MiniButton(title: busy ? "处理中…" : (installed ? "更新监控" : "启用监控"),
                           disabled: busy || !loaded) { apply() }
            }
            Text(status).font(.system(size: 12.5)).foregroundStyle(T.fg)
            Text("独立轻量进程，由系统开机启动和自动恢复；退出 midog 或停止内核后仍生效。命中的代理先正常退出，3 秒后仍存活则强制结束。启用和更新需管理员授权，应用内不提供停用或卸载入口。")
                .font(.system(size: 11)).foregroundStyle(T.muted)
            Text("内置目录按应用标识和内核文件名识别，不受安装目录影响。目录随版本更新，不可编辑；不会联网下载规则。")
                .font(.system(size: 11)).foregroundStyle(T.muted)
            DisclosureGroup("查看此版本内置目录（只读）") {
                ScrollView([.vertical, .horizontal]) {
                    Text(catalog)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 180)
                .background(Color(hex: 0x0E1418))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("已安装服务需点击「更新监控」才会使用此版本目录。目录不能穷尽全部代理，仍需配合系统内容过滤。")
                .font(.system(size: 11)).foregroundStyle(T.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task {
            if !loaded {
                do {
                    let raw = try await Task.detached { try WatchdogService.catalog() }.value
                    catalog = raw.split(separator: "\n").map { line in
                        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                        return fields.count >= 3 ? "\(fields[0]) · \(fields[1]): \(fields[2])" : String(line)
                    }.joined(separator: "\n")
                    loaded = true
                }
                catch { store.toast(error.localizedDescription, error: true) }
            }
            await refresh()
        }
    }

    private func refresh() async {
        status = await Task.detached { WatchdogService.status() }.value
        installed = WatchdogService.installed
    }

    private func apply() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached {
                    try WatchdogService.install()
                }.value
                store.toast("已安装并加载独立监控")
            } catch { store.toast(error.localizedDescription, error: true) }
            await refresh()
        }
    }
}
