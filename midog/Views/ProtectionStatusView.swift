import SwiftUI

/// Show live service reachability rather than treating installation as protection.
struct ProtectionStatusView: View {
    @ObservedObject private var focus = FocusStore.shared
    @ObservedObject private var watchdog = AppWatchdog.shared
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            statusItem(title: "App 屏蔽", icon: "app.badge.checkmark",
                       detail: watchdog.systemStatus.hasPrefix("监控运行中")
                           ? watchdog.systemStatus
                           : (watchdog.running ? "应用内监控中 · 系统监控未运行" : watchdog.status),
                       healthy: watchdog.systemStatus.hasPrefix("监控运行中") && watchdog.running)
            Rectangle().fill(T.line).frame(width: 1, height: 30)
            statusItem(title: "系统扩展屏蔽", icon: "shield.lefthalf.filled",
                       detail: focus.available ? (focus.state.filteringEnabled ? "过滤已开启" : "过滤已关闭") : "过滤服务未连接",
                       healthy: focus.available && focus.state.filteringEnabled)
            Button(action: openSettings) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(T.muted)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开屏蔽设置")
            .help("在设置中查看和管理屏蔽服务")
        }
        .card()
    }

    private func statusItem(title: String, icon: String, detail: String, healthy: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(T.muted)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(T.fg)
                HStack(spacing: 6) {
                    Circle().fill(healthy ? T.ok : T.warn).frame(width: 6, height: 6)
                    Text(detail).font(.system(size: 11)).foregroundStyle(healthy ? T.muted : T.warn)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
