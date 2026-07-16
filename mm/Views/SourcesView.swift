import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject var store: Store
    @State private var showAddSubscription = false
    @State private var deletingSource: Source?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionTitle("节点来源 · 订阅与本地文件")
                        Spacer()
                        MiniButton(title: "导入 YAML 文件…") { importFiles() }
                        AccentButton(title: "添加订阅") { showAddSubscription = true }
                    }

                    Text("每个启用的来源作为独立 proxy-provider 注入内核，可多选叠加。订阅更新只刷新对应 provider 的节点，不打断连接。")
                        .font(.system(size: 11))
                        .foregroundStyle(T.muted)

                    if store.data.sources.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 24))
                                .foregroundStyle(T.muted.opacity(0.5))
                            Text("暂无节点来源，添加订阅或导入本地 Clash YAML")
                                .font(.system(size: 12))
                                .foregroundStyle(T.muted)
                        }
                        .padding(.vertical, 36)
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(store.data.sources) { source in
                                sourceRow(source)
                                if source.id != store.data.sources.last?.id {
                                    Rectangle().fill(T.line.opacity(0.6)).frame(height: 1)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding(18)
        }
        .sheet(isPresented: $showAddSubscription) {
            AddSubscriptionSheet()
        }
        .confirmationDialog("确定删除节点来源 \(deletingSource?.displayName ?? "")？（配置文件将一并删除）",
                            isPresented: Binding(get: { deletingSource != nil },
                                                 set: { if !$0 { deletingSource = nil } })) {
            Button("删除", role: .destructive) {
                if let s = deletingSource {
                    Task { await store.deleteSource(s) }
                }
                deletingSource = nil
            }
            Button("取消", role: .cancel) { deletingSource = nil }
        }
    }

    private func sourceRow(_ source: Source) -> some View {
        let fileExists = FileManager.default.fileExists(
            atPath: AppPaths.configsDir.appendingPathComponent(source.name).path)

        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { on in Task { await store.toggleSource(source, enabled: on) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(T.accent)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(source.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(source.enabled ? T.fg : T.muted)
                    if source.displayName != source.name {
                        Text(source.name)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(T.muted.opacity(0.7))
                    }
                    Badge(text: source.isSubscription ? "订阅" : "本地",
                          color: source.isSubscription ? T.accent : T.muted)
                    if !fileExists {
                        Badge(text: "文件缺失", color: T.bad)
                    }
                }
                if let updated = source.updatedAt, !updated.isEmpty {
                    Text("更新于 \(formatTimestamp(updated))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.muted.opacity(0.8))
                }
            }

            Spacer()

            if source.isSubscription {
                MiniButton(title: "更新") {
                    Task { await store.updateSource(source) }
                }
            }
            MiniButton(title: "删除", role: .destructive) {
                deletingSource = source
            }
        }
        .padding(.vertical, 9)
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.yaml]
        panel.allowsOtherFileTypes = true
        panel.message = "选择 Clash 格式的 YAML 配置文件"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                for url in urls {
                    await store.importLocalFile(from: url)
                }
            }
        }
    }
}
