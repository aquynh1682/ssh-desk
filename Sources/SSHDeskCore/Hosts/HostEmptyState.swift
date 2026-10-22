import Foundation

/// Nội dung màn trống của danh sách máy chủ theo ngữ cảnh (ADR-022). Thuần, có test.
public enum HostEmptyState {
    public enum Scope: Equatable, Sendable {
        case all
        case favorites
        case recent
        case environment(HostEnvironment)
        case folder(String)
        case uncategorized
    }

    public struct Content: Equatable, Sendable {
        public var title: String
        public var message: String
        public var symbol: String
        /// Hiện nút "Thêm máy chủ".
        public var offersAdd: Bool
    }

    public static func content(scope: Scope, searching: Bool, hasAnyHosts: Bool) -> Content {
        if searching {
            return Content(
                title: "Không tìm thấy máy chủ", message: "Thử từ khoá khác (tên, host, user, tag).",
                symbol: "magnifyingglass", offersAdd: false)
        }
        if !hasAnyHosts {
            return Content(
                title: "Chưa có máy chủ nào",
                message: "Thêm máy chủ thủ công hoặc import các alias có sẵn trong ~/.ssh/config.",
                symbol: "server.rack", offersAdd: true)
        }
        switch scope {
        case .all:
            return Content(
                title: "Không có máy chủ nào khớp", message: "Bỏ bộ lọc môi trường để xem đủ danh sách.",
                symbol: "line.3.horizontal.decrease.circle", offersAdd: false)
        case .favorites:
            return Content(
                title: "Chưa có máy chủ yêu thích", message: "Bấm ngôi sao ở một máy chủ để ghim vào đây.",
                symbol: "star", offersAdd: false)
        case .recent:
            return Content(
                title: "Chưa mở máy chủ nào gần đây",
                message: "Máy chủ bạn mở bằng Warp hoặc Windows App sẽ hiện ở đây.",
                symbol: "clock", offersAdd: false)
        case .environment(let env):
            return Content(
                title: "Chưa có máy chủ \(env.rawValue)", message: "Đặt môi trường cho máy chủ trong form hồ sơ.",
                symbol: "tray", offersAdd: true)
        case .folder(let name):
            return Content(
                title: "Thư mục “\(name)” đang trống",
                message: "Thêm máy chủ mới, hoặc kéo máy chủ từ danh sách thả vào thư mục này ở thanh bên.",
                symbol: "folder", offersAdd: true)
        case .uncategorized:
            return Content(
                title: "Mọi máy chủ đã có thư mục", message: "Không còn máy chủ nào chưa phân loại.",
                symbol: "tray", offersAdd: false)
        }
    }
}
