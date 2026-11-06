import SwiftUI

struct ClientSubscriptionScanSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var result = ClientSubscriptionScanner.ScanResult()
    @State private var scanning = true
    @State private var importing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("扫描客户端订阅").font(.headline)
                Spacer()
                MiniButton(title: "重新扫描") { Task { await scan() } }
                    .disabled(scanning || importing != nil)
                MiniButton(title: "完成") { dismiss() }.disabled(importing != nil)
            }
            Text("读取本机客户端保存的 YAML 节点配置，校验内容后导入，无需访问订阅地址。")
                .font(.system(size: 12)).foregroundStyle(T.muted)
            if scanning {
                ProgressView("正在扫描…").frame(maxWidth: .infinity, minHeight: 150)
            } else if result.candidates.isEmpty {
                Text("未找到兼容订阅。请先在客户端中登录并加载节点，再重新扫描。")
                    .foregroundStyle(T.muted).frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(result.candidates) { candidate in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.label).font(.system(size: 13, weight: .medium))
                                    Text("\(candidate.origin) · 本地配置")
                                        .font(.system(size: 11)).foregroundStyle(T.muted)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                let added = store.data.sources.contains { $0.name == SubscriptionParser.sanitizeFileName(candidate.importName) }
                                MiniButton(title: added ? "已添加" : importing == candidate.id ? "添加中…" : "添加") {
                                    Task {
                                        importing = candidate.id
                                        await store.importLocalFile(from: candidate.file, name: candidate.importName)
                                        importing = nil
                                    }
                                }.disabled(added || importing != nil)
                            }.padding(10).background(T.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: 320)
            }
            if result.unreadable > 0 {
                Text("有 \(result.unreadable) 个数据库无法读取，可能被占用或没有访问权限。")
                    .font(.system(size: 11)).foregroundStyle(T.muted)
            }
            if result.truncated {
                Text("已达到扫描上限；扫描范围为 Application Support 下三层目录。")
                    .font(.system(size: 11)).foregroundStyle(T.muted)
            }
        }
        .padding(20).frame(width: 580).background(T.panel).preferredColorScheme(.dark)
        .task { await scan() }
    }

    private func scan() async {
        scanning = true
        result = await Task.detached(priority: .utility) { ClientSubscriptionScanner.scan() }.value
        scanning = false
    }
}
