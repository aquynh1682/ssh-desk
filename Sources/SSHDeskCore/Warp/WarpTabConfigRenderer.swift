import Foundation

/// Sinh nội dung file Tab Config (TOML) của Warp. Tên hiển thị chỉ vào `name`, không bao giờ vào `commands`.
public enum WarpTabConfigRenderer {
    /// Dòng đầu đánh dấu file do app sở hữu (dùng để bảo vệ namespace).
    public static let ownershipMarker = "# Do SSH Desk sinh"

    public static func render(displayName: String, command: String) -> String {
        """
        \(ownershipMarker) — không sửa tay
        name = \(tomlString(displayName))

        [[panes]]
        id = "main"
        type = "terminal"
        shell = "zsh"
        is_focused = true
        commands = [\(tomlString(command))]

        """
    }

    /// TOML basic string: escape `\`, `"` và mọi ký tự điều khiển.
    static func tomlString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\u{08}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += "\\u" + String(format: "%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
