import Foundation
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var store: Store
    @Binding var page: Page

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if store.data.sources.isEmpty {
                    onboardingCard
                }

                // KPI 行
                HStack(spacing: 14) {
                    kpiCard(title: "下行", value: formatRate(store.downRate),
                            sub: "累计 \(formatBytes(store.totalDown))",
                            spark: store.downHistory, color: T.accent)
                    kpiCard(title: "上行", value: formatRate(store.upRate),
                            sub: "累计 \(formatBytes(store.totalUp))",
                            spark: store.upHistory, color: T.warn)
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("活跃连接")
                        Text("\(store.connCount)")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(T.fg)
                        Text(store.connected ? "API 已连接" : "API 未连接")
                            .font(.system(size: 11))
                            .foregroundStyle(store.connected ? T.muted : T.warn)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("当前节点")
                        Text(store.currentProxyName ?? (store.data.mode == "direct" ? "直连" : "—"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(T.fg)
                            .lineLimit(1)
                        if let name = store.currentProxyName {
                            HStack(spacing: 6) {
                                DelayBadge(state: store.delays[name])
                                Button {
                                    Task { await store.testDelay(name) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 9))
                                        .foregroundStyle(T.muted)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            Text(store.running ? "" : "内核未运行")
                                .font(.system(size: 11))
                                .foregroundStyle(T.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                // 当前路由
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        SectionTitle("当前路由")
                        if let name = store.currentProxyName {
                            DelayBadge(state: store.delays[name])
                        }
                        Spacer()
                    }
                    if store.routePath.isEmpty {
                        Text(store.running ? "等待 API 连接…" : "内核未运行")
                            .font(.system(size: 12))
                            .foregroundStyle(T.muted)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(Array(store.routePath.enumerated()), id: \.offset) { idx, hop in
                                if idx > 0 {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9))
                                        .foregroundStyle(T.muted)
                                }
                                let isLast = idx == store.routePath.count - 1
                                Text(hop)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(isLast ? T.accent : T.fg)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(T.panel2)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(isLast ? T.accent.opacity(0.6) : T.line, lineWidth: 1))
                            }
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                // 日志预览
                recentLogsCard
            }
            .padding(18)
        }
    }

    private func kpiCard(title: String, value: String, sub: String, spark: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(T.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ZStack(alignment: .bottomLeading) {
                Sparkline(values: spark.isEmpty ? [0, 0] : spark, color: color)
                    .frame(height: 22)
                Text(sub)
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.muted)
                    .offset(y: 14)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var recentLogsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("日志")
                Spacer()
                Button { page = .logs } label: {
                    Text("全部 ›")
                        .font(.system(size: 11))
                        .foregroundStyle(T.muted)
                }
                .buttonStyle(.plain)
            }
            if store.logs.isEmpty {
                Text("等待日志输出…")
                    .font(.system(size: 12))
                    .foregroundStyle(T.muted)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.logs.suffix(9).reversed()) { log in
                        HStack(alignment: .top, spacing: 7) {
                            Text(log.level.rawValue.uppercased().prefix(4))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(log.level == .error ? T.bad : T.accent)
                            Text(log.message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(T.muted)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("开始使用")
            Text("还没有节点来源。先在「节点来源」添加订阅或导入本地 YAML，然后回到这里启动内核。")
                .font(.system(size: 12.5))
                .foregroundStyle(T.fg)
            AccentButton(title: "添加节点来源") { page = .sources }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
