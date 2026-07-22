import Foundation
import SwiftUI

// ============ 添加订阅 ============

struct AddSubscriptionSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加订阅")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(T.fg)

            field("名称", text: $name, placeholder: "订阅名称，如：机场A")
            field("订阅 URL", text: $url, placeholder: "https://…（Clash 格式订阅地址）")

            HStack {
                Spacer()
                MiniButton(title: "取消") { dismiss() }
                AccentButton(title: submitting ? "下载中…" : "添加",
                             disabled: submitting || name.trimmingCharacters(in: .whitespaces).isEmpty
                                       || url.trimmingCharacters(in: .whitespaces).isEmpty) {
                    submitting = true
                    Task {
                        let ok = await store.addSubscription(
                            name: name.trimmingCharacters(in: .whitespaces),
                            url: url.trimmingCharacters(in: .whitespaces))
                        submitting = false
                        if ok { dismiss() }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(T.panel)
        .preferredColorScheme(.dark)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(T.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(T.fg)
                .padding(8)
                .background(Color(hex: 0x0E1418))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.line, lineWidth: 1))
        }
    }
}

// ============ 添加远程规则集 ============

struct AddRuleProviderSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var form = Store.RuleProviderForm()
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加远程规则集")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(T.fg)

            field("名称（字母/数字/._-）", text: $form.name, placeholder: "例: ai")
            field("规则文件 URL", text: $form.url, placeholder: "https://…（yaml / 纯文本 / base64 / gfwlist / mrs）")

            HStack(spacing: 12) {
                picker("类型", selection: $form.behavior, options: [
                    ("auto", "自动识别（推荐）"),
                    ("classical", "classical"),
                    ("domain", "domain"),
                    ("ipcidr", "ipcidr")
                ])
                picker("格式", selection: $form.format, options: [
                    ("auto", "自动识别（推荐）"),
                    ("yaml", "yaml"),
                    ("text", "text"),
                    ("mrs", "mrs")
                ])
                ruleTargetPicker
            }

            Toggle(isOn: $form.viaProxy) {
                Text("通过代理下载（本机直连 GitHub/CDN 不通时保持勾选）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.muted)
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                MiniButton(title: "取消") { dismiss() }
                AccentButton(title: submitting ? "下载分析中…" : "添加",
                             disabled: submitting || form.name.trimmingCharacters(in: .whitespaces).isEmpty
                                       || form.url.trimmingCharacters(in: .whitespaces).isEmpty) {
                    submitting = true
                    Task {
                        let ok = await store.addRuleProvider(form)
                        submitting = false
                        if ok { dismiss() }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(T.panel)
        .preferredColorScheme(.dark)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(T.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(T.fg)
                .padding(8)
                .background(Color(hex: 0x0E1418))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.line, lineWidth: 1))
        }
    }

    private func picker(_ label: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(T.muted)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { value, title in
                    Text(title).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ruleTargetPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("命中后走")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(T.muted)
            Menu {
                Section("内置策略") {
                    ForEach(FINAL_TARGETS, id: \.self) { target in
                        ruleTargetButton(target, kind: "builtin")
                    }
                }
                if !store.ruleTargetGroups.isEmpty {
                    Section("分组") {
                        ForEach(store.ruleTargetGroups, id: \.self) { target in
                            ruleTargetButton(target, kind: "group")
                        }
                    }
                }
                if !store.ruleTargetNodes.isEmpty {
                    Section("节点") {
                        ForEach(store.ruleTargetNodes, id: \.self) { target in
                            ruleTargetButton(target, kind: "node")
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(form.target)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(store.connected ? "选择规则命中后的出站目标" : "启动并连接内核后可选择节点和分组")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ruleTargetButton(_ target: String, kind: String) -> some View {
        Button {
            form.target = target
            form.targetKind = kind
        } label: {
            HStack {
                Text(target)
                if form.target == target && form.targetKind == kind {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
