import SwiftUI

struct FocusSettingsView: View {
    @ObservedObject private var focus = FocusStore.shared
    @State private var domain = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("专注时屏蔽的网站")
                Spacer()
                Text("\(focus.state.domains.count) 个网站").font(.system(size: 11)).foregroundStyle(T.muted)
            }
            Text(focus.active ? "当前只能添加，新增立即生效并保留到下次。" : "可添加域名或粘贴网址，默认同时屏蔽该域名的所有子域名。")
                .font(.system(size: 12)).foregroundStyle(T.muted)
            HStack {
                TextField("例如 example.com 或 https://example.com", text: $domain)
                    .textFieldStyle(.roundedBorder).onSubmit { add() }
                AccentButton(title: "添加网站") { add() }
                    .disabled(domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || focus.busy || !focus.available)
            }
            if focus.state.domains.isEmpty {
                Text("先添加容易让你分心的网站，再开始专注。")
                    .foregroundStyle(T.muted).padding(.vertical, 22).frame(maxWidth: .infinity)
            }
            LazyVStack(spacing: 0) {
                ForEach(focus.state.domains, id: \.self) { host in
                    HStack {
                        Image(systemName: focus.active ? "lock.fill" : "globe").foregroundStyle(T.muted)
                        Text(host).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        if !focus.active {
                            MiniButton(title: "删除", role: .destructive) {
                                Task { await focus.perform(FocusCommand(action: .remove, domain: host)) }
                            }.disabled(focus.busy || !focus.available)
                        }
                    }.padding(.vertical, 10)
                    Divider()
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func add() {
        guard !focus.busy, focus.available, !domain.isEmpty else { return }
        let input = domain
        Task { if await focus.perform(FocusCommand(action: .add, domain: input)) { domain = "" } }
    }
}

private struct FocusDurationSheet: View {
    let extending: Bool
    @ObservedObject private var focus = FocusStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = "25"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(extending ? "延长专注" : "选择专注时长").font(.title2.bold())
            HStack {
                ForEach([25, 45, 60, 90], id: \.self) { value in
                    Button("\(value) 分钟") { minutes = String(value) }
                        .tint(minutes == String(value) ? T.accent : T.muted)
                }
            }
            HStack {
                Text("自定义")
                TextField("分钟", text: $minutes).textFieldStyle(.roundedBorder).frame(width: 100)
                Text("分钟（1–1440）").foregroundStyle(T.muted)
            }
            Text(extending ? "时间会加在本次结束时间之后，剩余时间最多 24 小时。" : "开始后不能暂停、缩短或提前结束，只能添加网站或延长时间。")
                .font(.system(size: 12)).foregroundStyle(T.muted)
            if !extending && focus.state.domains.isEmpty {
                Text("请先在设置中添加要屏蔽的网站。")
                    .font(.system(size: 12)).foregroundStyle(T.warn)
            }
            if let error = focus.error { Text(error).font(.system(size: 12)).foregroundStyle(T.warn) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.disabled(focus.busy)
                AccentButton(title: focus.busy ? "正在应用…" : extending ? "确认延长" : "开始专注") {
                    Task {
                        if await focus.perform(FocusCommand(action: extending ? .extend : .start, minutes: Int(minutes))) { dismiss() }
                    }
                }.disabled(focus.busy || !focus.available || (!extending && focus.state.domains.isEmpty) || !(1...1440).contains(Int(minutes) ?? 0))
            }
        }.padding(24).frame(width: 470)
    }
}

struct FocusSummaryCard: View {
    @ObservedObject private var focus = FocusStore.shared
    @State private var showDuration = false
    @State private var extending = false
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "timer").font(.system(size: 24)).foregroundStyle(T.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(focus.active ? "正在专注 · \(focus.remaining)" : "专注模式").font(.system(size: 16, weight: .semibold)).monospacedDigit()
                Text(focus.active ? "\(focus.state.domains.count) 个网站暂时屏蔽" : "选一段时间，暂时屏蔽让你分心的网站")
                    .font(.system(size: 12)).foregroundStyle(T.muted)
            }
            Spacer()
            AccentButton(title: focus.active ? "延长专注" : "开始专注", disabled: focus.busy) {
                extending = focus.active
                showDuration = true
            }
            .help(focus.active ? "选择要延长的专注时间" : "选择时长，开始专注")
        }.card()
        .sheet(isPresented: $showDuration) { FocusDurationSheet(extending: extending) }
    }
}
