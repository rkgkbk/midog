import Foundation
import SwiftUI

struct RulesView: View {
    @EnvironmentObject var store: Store
    @State private var draft = ""
    @State private var finalTarget = "PROXY"
    @State private var loaded = false
    @State private var showAddProvider = false
    @State private var deletingProvider: RuleProvider?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                editorCard
                providersCard
            }
            .padding(18)
        }
        .onAppear {
            if !loaded {
                draft = store.rulesText
                finalTarget = store.data.finalTarget
                loaded = true
            }
        }
        .sheet(isPresented: $showAddProvider) {
            AddRuleProviderSheet()
        }
        .confirmationDialog("确定删除远程规则集 \(deletingProvider?.name ?? "")？",
                            isPresented: Binding(get: { deletingProvider != nil },
                                                 set: { if !$0 { deletingProvider = nil } })) {
            Button("删除", role: .destructive) {
                if let p = deletingProvider {
                    Task { await store.deleteRuleProvider(p) }
                }
                deletingProvider = nil
            }
            Button("取消", role: .cancel) { deletingProvider = nil }
        }
    }

    // ---- 规则编辑器 ----

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("分流规则 · rules.txt")
                Spacer()
                MiniButton(title: "重新载入") {
                    draft = (try? String(contentsOf: AppPaths.rulesFile, encoding: .utf8))?
                        .replacingOccurrences(of: "\r\n", with: "\n") ?? store.rulesText
                    store.toast("已从文件重新载入")
                }
            }

            Text("每行一条，格式: 类型,匹配内容,目标（PROXY / AUTO / DIRECT / REJECT），# 开头为注释，仅 RULE 模式生效。规则独立保存在 rules.txt，也可用编辑器直接修改后回来重载。")
                .font(.system(size: 11))
                .foregroundStyle(T.muted)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(T.fg)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 260)
                .background(Color(hex: 0x0E1418))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))

            HStack(spacing: 10) {
                Text("兜底 (MATCH):")
                    .font(.system(size: 12))
                    .foregroundStyle(T.muted)
                HStack(spacing: 0) {
                    ForEach(FINAL_TARGETS, id: \.self) { target in
                        let active = finalTarget == target
                        Button {
                            finalTarget = target
                        } label: {
                            Text(target)
                                .font(.system(size: 10.5, weight: active ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(active ? Color(hex: 0x0C1417) : T.muted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(active ? T.accent : .clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line, lineWidth: 1))

                Spacer()

                AccentButton(title: "保存并应用") {
                    Task { await store.saveRules(text: draft, finalTarget: finalTarget) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // ---- 远程规则集 ----

    private var providersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("远程规则集 (rule-providers)")
                Spacer()
                AccentButton(title: "添加规则集") { showAddProvider = true }
            }

            Text("引用 GitHub/CDN 上维护的规则文件，默认在你的规则之后、兜底之前生效；在上方手写 RULE-SET,名称,目标 可自定义优先级。base64/gfwlist 等格式会自动转换后供内核使用。")
                .font(.system(size: 11))
                .foregroundStyle(T.muted)
                .fixedSize(horizontal: false, vertical: true)

            if store.data.ruleProviders.isEmpty {
                Text("暂无远程规则集")
                    .font(.system(size: 12))
                    .foregroundStyle(T.muted)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.data.ruleProviders) { provider in
                        providerRow(provider)
                        if provider.id != store.data.ruleProviders.last?.id {
                            Rectangle().fill(T.line.opacity(0.6)).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task { await store.refreshRuleRuntime() }
    }

    private func providerRow(_ provider: RuleProvider) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { provider.enabled },
                set: { on in Task { await store.toggleRuleProvider(provider, enabled: on) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(T.accent)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(provider.name)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(provider.enabled ? T.fg : T.muted)
                    Badge(text: "\(provider.behavior) → \(provider.target)", color: T.accent)
                    if provider.converted {
                        Badge(text: "\(provider.sourceFormat ?? "") → 已转换", color: T.warn)
                    }
                    if let rt = store.ruleRuntime[provider.name], let count = rt.ruleCount {
                        Text("\(count) 条 · \(formatTimestamp(rt.updatedAt))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(T.muted)
                    } else if provider.enabled {
                        Text(store.running ? "未加载" : "")
                            .font(.system(size: 10.5))
                            .foregroundStyle(T.muted)
                    }
                }
                Text(provider.url)
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.muted.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            MiniButton(title: "刷新") {
                Task { await store.refreshRuleProvider(provider) }
            }
            MiniButton(title: "删除", role: .destructive) {
                deletingProvider = provider
            }
        }
        .padding(.vertical, 9)
    }
}
