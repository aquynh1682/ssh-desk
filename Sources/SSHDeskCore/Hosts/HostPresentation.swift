import Foundation

/// Logic trình bày danh sách máy chủ (đếm, lọc, sắp xếp, dòng chi tiết). Thuần, không phụ thuộc UI.
public enum HostPresentation {
    /// Thứ tự hiển thị mục "MÔI TRƯỜNG" ở sidebar.
    public static let environmentOrder: [HostEnvironment] = [.prod, .uat, .stg, .dev, .other]

    public static func title(for env: HostEnvironment) -> String {
        switch env {
        case .prod: return "Production"
        case .uat: return "UAT"
        case .stg: return "Staging"
        case .dev: return "Dev"
        case .other: return "Khác"
        }
    }

    /// Mã ngắn trên badge.
    public static func badgeCode(for env: HostEnvironment) -> String {
        env == .other ? "KHÁC" : env.rawValue
    }

    /// Chỉ các môi trường có ít nhất một máy, theo `environmentOrder`.
    public static func environmentCounts(_ hosts: [HostProfile]) -> [(
        environment: HostEnvironment, count: Int
    )] {
        environmentOrder.compactMap { env in
            let n = hosts.filter { $0.environment == env }.count
            return n > 0 ? (env, n) : nil
        }
    }

    /// `nil` = tất cả môi trường.
    public static func filter(_ hosts: [HostProfile], environment: HostEnvironment?)
        -> [HostProfile]
    {
        guard let environment else { return hosts }
        return hosts.filter { $0.environment == environment }
    }

    /// Gần đây: chỉ máy đã từng yêu cầu mở Warp, mới nhất trước.
    public static func recent(_ hosts: [HostProfile], limit: Int? = nil) -> [HostProfile] {
        let sorted = hosts.filter { $0.lastLaunchRequestedAt != nil }
            .sorted {
                ($0.lastLaunchRequestedAt ?? .distantPast)
                    > ($1.lastLaunchRequestedAt ?? .distantPast)
            }
        if let limit { return Array(sorted.prefix(max(0, limit))) }
        return sorted
    }

    public static func sortedByName(_ hosts: [HostProfile], ascending: Bool) -> [HostProfile] {
        hosts.sorted {
            let r = $0.displayName.localizedStandardCompare($1.displayName)
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }

    /// Cột ĐỊA CHỈ: máy managed hiện host, máy imported hiện alias.
    public static func addressText(_ host: HostProfile) -> String {
        switch host.connectionMode {
        case .managed: return host.hostName
        case .existingSSHConfigAlias: return host.sshConfigAlias ?? "?"
        }
    }

    /// Phụ đề ở chi tiết: dòng đầu của ghi chú, nếu không có thì dự án.
    public static func subtitle(_ host: HostProfile) -> String {
        let firstLine = host.notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return firstLine ?? host.project
    }

    public static func authLabel(_ method: HostAuthMethod) -> String {
        switch method {
        case .agent: return "ssh-agent"
        case .keyFile: return "Khoá SSH"
        case .interactive: return "Nhập khi kết nối"
        }
    }

    public struct ConnectionRow: Equatable, Sendable {
        public let label: String
        public let value: String
        /// Có nút copy không. Giá trị ở đây không bao giờ là bí mật.
        public let copyable: Bool
    }

    /// Các dòng thẻ "Kết nối". Chỉ chứa dữ liệu không bí mật (tên file khoá, không phải nội dung).
    public static func connectionRows(_ host: HostProfile, jumpHostName: String?)
        -> [ConnectionRow]
    {
        switch host.connectionMode {
        case .managed:
            var rows = [
                ConnectionRow(label: "Địa chỉ", value: host.hostName, copyable: true),
                ConnectionRow(label: "Port", value: String(host.port), copyable: true),
                ConnectionRow(label: "User", value: host.user, copyable: true),
                ConnectionRow(
                    label: "Xác thực", value: authLabel(host.authMethod), copyable: false),
            ]
            if host.authMethod == .keyFile, let f = host.identityFile, !f.isEmpty {
                rows.append(
                    ConnectionRow(
                        label: "Key", value: URL(fileURLWithPath: f).lastPathComponent,
                        copyable: true))
            }
            if let jumpHostName {
                rows.append(ConnectionRow(label: "Jump host", value: jumpHostName, copyable: true))
            }
            return rows
        case .existingSSHConfigAlias:
            var rows = [
                ConnectionRow(label: "Alias", value: host.sshConfigAlias ?? "?", copyable: true)
            ]
            if let p = host.sshConfigPath {
                rows.append(ConnectionRow(label: "File nguồn", value: p, copyable: true))
            }
            return rows
        }
    }
}
