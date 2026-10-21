import AppKit
import SwiftUI

/// Màu và kích thước dùng chung. Mọi màu là dynamic: tự đổi theo sáng/tối của hệ thống.
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // Nền
    static let windowBackground = dynamic(light: rgb(0xF4F4F6), dark: rgb(0x0A0A0C))
    static let sidebarBackground = dynamic(light: rgb(0xECECEF), dark: rgb(0x0E0E10))
    static let card = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x151517))
    static let cardStroke = dynamic(
        light: NSColor.black.withAlphaComponent(0.09), dark: NSColor.white.withAlphaComponent(0.08))
    static let rowSelected = dynamic(light: rgb(0x000000, 0.06), dark: rgb(0xFFFFFF, 0.07))
    static let rowHover = dynamic(light: rgb(0x000000, 0.03), dark: rgb(0xFFFFFF, 0.04))
    static let divider = dynamic(
        light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.07))
    static let control = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x151517))

    // Chữ
    static let textPrimary = dynamic(light: rgb(0x1A1A1C), dark: rgb(0xF2F2F4))
    static let textSecondary = dynamic(light: rgb(0x6B6B72), dark: rgb(0x9A9AA2))
    static let textTertiary = dynamic(light: rgb(0x9A9AA2), dark: rgb(0x6C6C74))

    // Nút trắng nổi (Thêm máy chủ, Mở Warp): trắng ở tối, đen ở sáng.
    static let prominentFill = dynamic(light: rgb(0x1A1A1C), dark: rgb(0xFFFFFF))
    static let prominentText = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x111113))

    // Màu trạng thái
    static let green = dynamic(light: rgb(0x1F9D4D), dark: rgb(0x3DDC6B))
    static let red = dynamic(light: rgb(0xD92D20), dark: rgb(0xFF6B60))
    static let star = dynamic(light: rgb(0xE5A100), dark: rgb(0xFFC933))
    static let amber = dynamic(light: rgb(0xB36B00), dark: rgb(0xF2B24A))
    static let blue = dynamic(light: rgb(0x1D6FD8), dark: rgb(0x6FB1FF))

    static func environmentColor(_ env: HostEnvironmentStyle) -> Color {
        switch env {
        case .warm: return amber
        case .cool: return blue
        case .neutral: return textSecondary
        }
    }

    // Kích thước
    static let corner: CGFloat = 10
    static let cardCorner: CGFloat = 12
    static let sidebarWidth: CGFloat = 220
    static let detailWidth: CGFloat = 340
}

/// Phân loại màu badge môi trường: PROD ấm, STG lạnh, còn lại xám.
enum HostEnvironmentStyle {
    case warm, cool, neutral
}

extension View {
    /// Thẻ nền + viền mảnh bo góc.
    func cardStyle(corner: CGFloat = Theme.cardCorner) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Theme.cardStroke))
    }
}

/// Nút đặc nổi (trắng ở tối / đen ở sáng).
struct ProminentButtonStyle: ButtonStyle {
    var fullWidth = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.prominentText)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Theme.prominentFill, in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Nút viền (Tải lên / Tải về, Menu lọc).
struct OutlineButtonStyle: ButtonStyle {
    var fullWidth = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Theme.control.opacity(0.0001), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.textTertiary.opacity(0.6)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
