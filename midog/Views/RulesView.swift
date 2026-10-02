import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        .confirmationDialog("确定删除规则集 \(deletingProvider?.name ?? "")？",
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

    // ---- 规则集 ----

    private var providersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("规则集 (rule-providers)")
                Spacer()
                MiniButton(title: "导入本地规则集") { importLocalRuleProviders() }
                AccentButton(title: "添加规则集") { showAddProvider = true }
            }

            Text("支持添加远程规则集或导入本地 YAML、文本、base64/gfwlist、MRS 文件。点击规则后的目标可选择内置策略、分组或节点；在上方手写 RULE-SET,名称,目标 可自定义优先级。")
                .font(.system(size: 11))
                .foregroundStyle(T.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(MANDATORY_RULE_PROVIDERS) { item in
                    mandatoryProviderRow(item.provider)
                    Rectangle().fill(T.line.opacity(0.6)).frame(height: 1)
                }
            }

            if store.data.ruleProviders.isEmpty {
                Text("暂无自定义规则集")
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
        .task {
            await store.refreshRuleRuntime()
            await store.refreshProxies()
        }
    }

    /// 内置强制规则集：只读展示，没有开关和删除按钮
    private func mandatoryProviderRow(_ provider: RuleProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(T.muted)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(provider.name)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    Badge(text: provider.behavior, color: T.accent)
                    Badge(text: "内置 · 强制 \(provider.target)", color: T.warn)
                    if let rt = store.ruleRuntime[provider.name], let count = rt.ruleCount {
                        Text("\(count) 条 · \(formatTimestamp(rt.updatedAt))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(T.muted)
                    } else if store.running {
                        Text("未加载")
                            .font(.system(size: 10.5))
                            .foregroundStyle(T.muted)
                    }
                }
                Text(provider.sourceDisplayText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.muted.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text("不可修改")
                .font(.system(size: 10.5))
                .foregroundStyle(T.muted)
        }
        .padding(.vertical, 9)
        .help("内置于 App 的强制规则集，排在所有用户规则之前，无法在界面中关闭或删除")
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
                    Badge(text: provider.behavior, color: T.accent)
                    ruleTargetMenu(provider)
                    if provider.isLocal {
                        Badge(text: "本地", color: T.muted)
                    } else if provider.converted {
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
                Text(provider.sourceDisplayText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.muted.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !provider.isLocal {
                MiniButton(title: "刷新") {
                    Task { await store.refreshRuleProvider(provider) }
                }
            }
            MiniButton(title: "删除", role: .destructive) {
                deletingProvider = provider
            }
        }
        .padding(.vertical, 9)
    }

    private func ruleTargetMenu(_ provider: RuleProvider) -> some View {
        Menu {
            Section("内置策略") {
                ForEach(FINAL_TARGETS, id: \.self) { target in
                    targetButton(target, kind: "builtin", provider: provider)
                }
            }
            if !store.ruleTargetGroups.isEmpty {
                Section("分组") {
                    ForEach(store.ruleTargetGroups, id: \.self) { target in
                        targetButton(target, kind: "group", provider: provider)
                    }
                }
            }
            if !store.ruleTargetNodes.isEmpty {
                Section("节点") {
                    ForEach(store.ruleTargetNodes, id: \.self) { target in
                        targetButton(target, kind: "node", provider: provider)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("→ \(provider.target)")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(T.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(T.accent.opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(store.connected ? "选择命中该规则文件后使用的分组或节点" : "启动并连接内核后可选择节点和分组")
    }

    private func targetButton(_ target: String, kind: String, provider: RuleProvider) -> some View {
        Button {
            Task { await store.updateRuleProviderTarget(provider, target: target, kind: kind) }
        } label: {
            HStack {
                Text(target)
                if provider.target == target && provider.targetKind == kind {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func importLocalRuleProviders() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .yaml,
            .plainText,
            UTType(filenameExtension: "mrs") ?? .data
        ]
        panel.allowsOtherFileTypes = true
        panel.message = "选择 YAML、文本、base64/gfwlist 或 MRS 规则集文件"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                for url in urls {
                    await store.importLocalRuleProvider(from: url)
                }
            }
        }
    }
}
