import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// 「驾驶舱」设计令牌：深色石墨蓝 + 青绿强调色
enum T {
    static let bg = Color(hex: 0x12181D)
    static let panel = Color(hex: 0x1A2229)
    static let panel2 = Color(hex: 0x1F2932)
    static let line = Color(hex: 0x2A3641)
    static let fg = Color(hex: 0xE6EDF2)
    static let muted = Color(hex: 0x7F93A1)
    static let accent = Color(hex: 0x41C6B3)
    static let ok = Color(hex: 0x43CF7C)
    static let warn = Color(hex: 0xE8B84A)
    static let bad = Color(hex: 0xE46A5F)

    static func delayColor(_ ms: Int) -> Color {
        if ms < 200 { return ok }
        if ms < 500 { return warn }
        return bad
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(T.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line, lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
