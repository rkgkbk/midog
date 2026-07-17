import Foundation
import SwiftUI

// ============ 通用小组件 ============

struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(1.2)
            .foregroundStyle(T.muted)
    }
}

struct Badge: View {
    let text: String
    var color: Color = T.muted

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct DelayBadge: View {
    let state: DelayState?

    var body: some View {
        Text(state?.text ?? "—")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .help(failureReason ?? "")
    }

    private var color: Color {
        switch state {
        case .ms(let v): return T.delayColor(v)
        case .testing: return T.muted
        case .timeout, .failed: return T.bad
        case nil: return T.muted.opacity(0.5)
        }
    }

    private var failureReason: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }
}

struct StatusDot: View {
    let on: Bool
    var onColor: Color = T.ok

    var body: some View {
        Circle()
            .fill(on ? onColor : T.muted.opacity(0.4))
            .frame(width: 7, height: 7)
    }
}

/// 小号操作按钮
struct MiniButton: View {
    let title: String
    var role: ButtonRole?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(role == .destructive ? T.bad : T.fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(T.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(title)
    }
}

struct AccentButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x0C1417))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(T.accent)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(title)
    }
}

/// 出站模式分段切换
struct ModeSegment: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 0) {
            ForEach(["rule", "global", "direct"], id: \.self) { mode in
                let active = store.data.mode == mode
                Button {
                    Task { await store.setMode(mode) }
                } label: {
                    Text(Self.modeTitle(mode))
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color(hex: 0x0C1417) : T.muted)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(active ? T.accent : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.line, lineWidth: 1))
    }

    private static func modeTitle(_ mode: String) -> String {
        switch mode {
        case "rule": return "规则"
        case "global": return "全局"
        case "direct": return "直连"
        default: return mode
        }
    }
}

/// TUN 开关胶囊
struct TunPill: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Button {
            Task { await store.toggleTun() }
        } label: {
            HStack(spacing: 8) {
                Text("代理")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(T.muted)
                ZStack(alignment: store.tunDisplayOn ? .trailing : .leading) {
                    Capsule()
                        .fill(store.tunDisplayOn ? T.accent : T.panel2)
                        .frame(width: 32, height: 18)
                        .overlay(Capsule().stroke(T.line, lineWidth: 1))
                    Circle()
                        .fill(store.tunDisplayOn ? Color(hex: 0x0E1519) : T.muted)
                        .frame(width: 13, height: 13)
                        .padding(.horizontal, 2.5)
                }
                .animation(.easeInOut(duration: 0.15), value: store.tunDisplayOn)
                Text(store.tunDisplayOn ? "ON" : "OFF")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(store.tunDisplayOn ? T.accent : T.muted)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(store.privileged ? "接管系统全部流量" : "开启 TUN 需要先给内核提权（见「设置」）")
    }
}

/// 迷你走势图
struct Sparkline: View {
    let values: [Double]
    var color: Color = T.accent

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 1, 1)
            let count = max(values.count, 2)
            let stepX = geo.size.width / CGFloat(count - 1)
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * stepX,
                        y: geo.size.height * (1 - CGFloat(v / peak) * 0.9) - 1)
            }
            ZStack {
                if points.count >= 2 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        for pt in points { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.12))
                    Path { p in
                        p.move(to: points[0])
                        for pt in points.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, lineWidth: 1.5)
                }
            }
        }
    }
}

/// Toast 浮层
struct ToastStack: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(toast.isError ? T.bad : T.accent)
                    Text(toast.text)
                        .font(.system(size: 12))
                        .foregroundStyle(T.fg)
                        .lineLimit(3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(T.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(toast.isError ? T.bad.opacity(0.5) : T.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 16)
        .animation(.spring(duration: 0.25), value: store.toasts)
        .frame(maxWidth: 480)
    }
}

// ============ 工具函数 ============

func formatRate(_ bytesPerSec: Int) -> String {
    let v = Double(bytesPerSec)
    if v >= 1_048_576 { return String(format: "%.1f MB/s", v / 1_048_576) }
    if v >= 1024 { return String(format: "%.0f KB/s", v / 1024) }
    return "\(bytesPerSec) B/s"
}

func formatBytes(_ bytes: Int) -> String {
    let v = Double(bytes)
    if v >= 1_073_741_824 { return String(format: "%.2f GB", v / 1_073_741_824) }
    if v >= 1_048_576 { return String(format: "%.1f MB", v / 1_048_576) }
    if v >= 1024 { return String(format: "%.0f KB", v / 1024) }
    return "\(bytes) B"
}

func formatTimestamp(_ iso: String?) -> String {
    guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

func formatUptime(since date: Date?) -> String {
    guard let date else { return "" }
    let s = Int(Date().timeIntervalSince(date))
    let h = s / 3600, m = (s % 3600) / 60
    if h > 0 { return "\(h) 小时 \(m) 分" }
    if m > 0 { return "\(m) 分钟" }
    return "刚刚启动"
}
