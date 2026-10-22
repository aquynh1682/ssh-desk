import Foundation

/// Việc đang chạy khi người dùng thoát app (ADR-022). Thuần dữ liệu: UI chỉ điền số liệu rồi hỏi
/// `needsConfirmation` / `lines`. Tab duyệt file mở nhưng rảnh không tính (đóng im lặng khi thoát).
public struct QuitActivity: Equatable, Sendable {
    /// Job truyền file đang chạy hoặc đang chờ.
    public var transfers: Int
    /// Tunnel `ssh -N -L` đang kết nối/chạy.
    public var tunnels: Int
    public var monitorRunning: Bool
    public var analystRunning: Bool
    /// Tác vụ SSH Keys (tạo key / cài key) đang chạy.
    public var keyTaskRunning: Bool

    public init(
        transfers: Int = 0, tunnels: Int = 0, monitorRunning: Bool = false,
        analystRunning: Bool = false, keyTaskRunning: Bool = false
    ) {
        self.transfers = max(0, transfers)
        self.tunnels = max(0, tunnels)
        self.monitorRunning = monitorRunning
        self.analystRunning = analystRunning
        self.keyTaskRunning = keyTaskRunning
    }

    public var needsConfirmation: Bool { !lines.isEmpty }

    /// Mỗi loại đang chạy một dòng, thứ tự cố định.
    public var lines: [String] {
        var out: [String] = []
        if transfers > 0 { out.append("\(transfers) tác vụ truyền file (đang chạy hoặc đang chờ)") }
        if tunnels > 0 { out.append("\(tunnels) tunnel port forward đang chạy") }
        if monitorRunning { out.append("Monitor đang theo dõi tài nguyên server") }
        if analystRunning { out.append("Project Analyst đang kiểm tra") }
        if keyTaskRunning { out.append("Tác vụ SSH Keys đang chạy") }
        return out
    }

    public static let title = "Thoát SSH Desk?"
    public static let confirmButton = "Dừng tất cả và thoát"
    public static let cancelButton = "Tiếp tục chạy"

    public var message: String {
        guard needsConfirmation else { return "" }
        let list = lines.map { "• \($0)" }.joined(separator: "\n")
        var text = "Đang có:\n\(list)\n\nThoát bây giờ sẽ dừng tất cả."
        if transfers > 0 {
            text += " Tác vụ truyền file bị huỷ hoặc ghi là “Bị gián đoạn” (thử lại được ở lịch sử)."
        }
        return text
    }
}

/// Khi đóng cửa sổ chính (ADR-021/022).
public enum WindowCloseDecision {
    /// App có thoát khi cửa sổ cuối đóng không.
    public static func quitsOnLastWindowClose(_ settings: AppSettings) -> Bool {
        settings.closeBehavior == .quit
    }
}
