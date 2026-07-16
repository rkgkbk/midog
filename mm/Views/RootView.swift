import Foundation
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case dashboard, nodes, rules, sources, logs, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "总览"
        case .nodes: return "节点"
        case .rules: return "分流规则"
        case .sources: return "节点来源"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .nodes: return "globe.asia.australia"
        case .rules: return "list.bullet.rectangle"
        case .sources: return "tray.and.arrow.down"
        case .logs: return "doc.plaintext"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var page: Page = .dashboard

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page)
                .frame(width: 200)
            Rectangle().fill(T.line).frame(width: 1)
            VStack(spacing: 0) {
                TopBar(page: page)
                Rectangle().fill(T.line).frame(height: 1)
                if let error = store.startupError {
                    ErrorBanner(text: error) { store.startupError = nil }
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(T.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1060, minHeight: 680)
        .overlay(alignment: .bottom) { ToastStack() }
        .task { await store.runLoops() }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .dashboard: DashboardView(page: $page)
        case .nodes: NodesView()
        case .rules: RulesView()
        case .sources: SourcesView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}

// ============ 侧边栏 ============

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [T.accent, Color(hex: 0x2B8F82)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                Text("MIHOMO")
                    .font(.system(size: 13, weight: .bold))
                    .kerning(2)
                    .foregroundStyle(T.fg)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 16)

            ForEach(Page.allCases) { p in
                SidebarItem(page: p, selected: page == p) { page = p }
            }

            Spacer()

            coreStatusCard
        }
        .padding(12)
        .background(T.bg)
    }

    private var coreStatusCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                StatusDot(on: store.running, onColor: store.connected ? T.ok : T.warn)
                Text(store.running ? (store.connected ? "内核运行中" : "内核启动中…") : "内核未运行")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.running ? T.fg : T.muted)
            }
            if store.running {
                Text([
                    store.coreVersion.isEmpty ? nil : store.coreVersion,
                    store.pid.map { "PID \($0)" },
                    formatUptime(since: store.startedAt).isEmpty ? nil : "已运行 \(formatUptime(since: store.startedAt))"
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.muted)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text("TUN")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(T.muted)
                Text(store.tunDisplayOn ? "ON" : "OFF")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(store.tunDisplayOn ? T.accent : T.muted)
                Text("·")
                    .foregroundStyle(T.muted)
                Text(store.data.mode.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(T.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(T.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
    }
}

struct SidebarItem: View {
    let page: Page
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .font(.system(size: 13))
                    .frame(width: 17)
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? T.fg : (hovering ? T.fg : T.muted))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? T.panel2 : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// ============ 错误横幅 ============

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(T.bad)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(T.fg)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(T.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.bad.opacity(0.12))
        .overlay(Rectangle().fill(T.bad.opacity(0.5)).frame(height: 1), alignment: .bottom)
        .accessibilityIdentifier("startup-error")
    }
}

// ============ 顶部工具栏 ============

struct TopBar: View {
    @EnvironmentObject var store: Store
    let page: Page

    var body: some View {
        HStack(spacing: 14) {
            Text(page.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(T.fg)

            Spacer()

            ModeSegment()
            TunPill()

            HStack(spacing: 8) {
                if store.running {
                    MiniButton(title: "重启", disabled: store.busy) {
                        Task { await store.restartCore() }
                    }
                    Button {
                        Task { await store.stopCore() }
                    } label: {
                        Text("停止")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(T.bad)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(T.bad.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.bad.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.busy)
                    .accessibilityLabel("停止")
                } else {
                    AccentButton(title: "启动内核", disabled: store.busy) {
                        Task { await store.startCore() }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(T.bg)
    }
}
