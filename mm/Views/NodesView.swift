import Foundation
import SwiftUI

struct NodesView: View {
    @EnvironmentObject var store: Store
    @State private var selectedGroup: String?

    private var groupNames: [String] {
        let names = store.proxies.filter { $0.value.isGroup }.keys.sorted()
        // PROXY / GLOBAL / AUTO 排前面
        let pinned = ["PROXY", "AUTO", "GLOBAL"].filter { names.contains($0) }
        return pinned + names.filter { !pinned.contains($0) }
    }

    private var currentGroup: String {
        if let selectedGroup, store.proxies[selectedGroup] != nil { return selectedGroup }
        return store.activeGroupName
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.data.mode == "direct" {
                emptyState("DIRECT 模式下所有流量直连，不经过代理节点")
            } else if !store.connected {
                emptyState(store.running ? "等待 mihomo API 连接…" : "内核未运行，启动后可选择节点")
            } else {
                header
                Rectangle().fill(T.line).frame(height: 1)
                nodeList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(groupNames, id: \.self) { name in
                    Button {
                        selectedGroup = name
                    } label: {
                        HStack {
                            Text(name)
                            if let t = store.proxies[name]?.type {
                                Text("(\(t))")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentGroup)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(T.fg)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(T.muted)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(T.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.line, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let g = store.proxies[currentGroup] {
                Text("\(g.all?.count ?? 0) 个节点 · \(g.type ?? "")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.muted)
            }

            Spacer()

            // 路由链
            Text(store.routePath.joined(separator: " → "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(T.muted)
                .lineLimit(1)

            MiniButton(title: store.testingAll ? "测速中…" : "测全部延迟",
                       disabled: store.testingAll) {
                Task { await store.testAllDelays(group: currentGroup) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var nodeList: some View {
        ScrollView {
            let group = store.proxies[currentGroup]
            let all = group?.all ?? []
            let selectable = group?.isSelectable ?? false
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(all, id: \.self) { name in
                    let node = store.proxies[name]
                    let isCurrent = group?.now == name
                    Button {
                        guard selectable else { return }
                        Task { await store.selectProxy(group: currentGroup, name: name) }
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(isCurrent ? T.accent : T.line)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? T.accent : T.fg)
                                    .lineLimit(1)
                                if let node, node.isGroup {
                                    Text("\(node.type ?? "") · \(node.now ?? "")")
                                        .font(.system(size: 10))
                                        .foregroundStyle(T.muted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            DelayBadge(state: store.delays[name])
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(isCurrent ? T.panel2 : T.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .stroke(isCurrent ? T.accent.opacity(0.55) : T.line, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!selectable)
                }
            }
            .padding(18)
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "globe.asia.australia")
                .font(.system(size: 28))
                .foregroundStyle(T.muted.opacity(0.5))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(T.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
