import Foundation
import SwiftUI

struct LogsView: View {
    @EnvironmentObject var store: Store
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(store.logs.count) 条（最多保留 500 条）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.muted)
                Spacer()
                Toggle(isOn: $autoScroll) {
                    Text("自动滚动")
                        .font(.system(size: 11.5))
                        .foregroundStyle(T.muted)
                }
                .toggleStyle(.checkbox)
                MiniButton(title: "清空") { store.clearLogs() }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Rectangle().fill(T.line).frame(height: 1)

            if store.logs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 26))
                        .foregroundStyle(T.muted.opacity(0.5))
                    Text("等待日志输出…")
                        .font(.system(size: 13))
                        .foregroundStyle(T.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(store.logs) { log in
                                logRow(log).id(log.id)
                            }
                        }
                        .padding(14)
                    }
                    .background(Color(hex: 0x0E1418))
                    .onChange(of: store.logs.count) {
                        if autoScroll, let last = store.logs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let last = store.logs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ log: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(Self.timeFormatter.string(from: log.date))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(T.muted.opacity(0.7))
            Text(levelLabel(log.level))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(levelColor(log.level))
                .frame(width: 34, alignment: .leading)
            Text(log.message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(T.fg.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func levelLabel(_ level: LogEntry.Level) -> String {
        switch level {
        case .info: return "INFO"
        case .error: return "ERR"
        case .system: return "SYS"
        }
    }

    private func levelColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return T.accent
        case .error: return T.bad
        case .system: return T.warn
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
