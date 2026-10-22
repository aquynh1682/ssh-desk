import Foundation

/// Cách chỉ tới host trong URL từ bên ngoài.
public enum URLHostReference: Equatable, Sendable {
    case id(UUID)
    case name(String)
}

/// URL `sshdesk://` đã được kiểm tra cú pháp (ADR-025). Chỉ có hai dạng; mọi thứ khác bị từ chối.
public enum AppURLRequest: Equatable, Sendable {
    /// `sshdesk://cli?request=<uuid>` — phải đối chiếu với file yêu cầu của CLI.
    case fromCLI(requestID: UUID)
    /// `sshdesk://open?id=<uuid>` hoặc `?name=<...>` — nguồn không tin cậy.
    case external(URLHostReference)

    public static let maxValueLength = 256

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notOurScheme
        case unknownAction
        case badQuery(String)
        case badValue(String)

        public var description: String {
            switch self {
            case .notOurScheme: return "Không phải URL sshdesk://."
            case .unknownAction: return "URL sshdesk:// không hỗ trợ thao tác này (chỉ open và cli)."
            case .badQuery(let s): return "URL sshdesk:// không hợp lệ: \(s)."
            case .badValue(let s): return "URL sshdesk:// không hợp lệ: \(s)."
            }
        }
    }

    public static func parse(_ url: URL) throws -> AppURLRequest {
        guard url.scheme?.lowercased() == "sshdesk" else { throw ParseError.notOurScheme }
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ParseError.badQuery("không phân tích được")
        }
        guard c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
            c.path.isEmpty || c.path == "/"
        else { throw ParseError.badQuery("có thành phần thừa") }
        let action = (c.host ?? "").lowercased()
        guard action == "open" || action == "cli" else { throw ParseError.unknownAction }

        let items = c.queryItems ?? []
        guard items.count == 1, let item = items.first else {
            throw ParseError.badQuery("cần đúng một tham số")
        }
        guard let value = item.value else { throw ParseError.badValue("tham số thiếu giá trị") }
        try checkValue(value)

        switch (action, item.name) {
        case ("cli", "request"):
            guard let id = UUID(uuidString: value) else { throw ParseError.badValue("request không phải UUID") }
            return .fromCLI(requestID: id)
        case ("open", "id"):
            guard let id = UUID(uuidString: value) else { throw ParseError.badValue("id không phải UUID") }
            return .external(.id(id))
        case ("open", "name"):
            return .external(.name(value))
        default:
            throw ParseError.badQuery(
                "tham số “\(HostResolver.printable(String(item.name.prefix(20))))” không được phép")
        }
    }

    private static func checkValue(_ v: String) throws {
        if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ParseError.badValue("giá trị rỗng") }
        if v.count > maxValueLength { throw ParseError.badValue("giá trị dài quá \(maxValueLength) ký tự") }
        if v.unicodeScalars.contains(where: HostResolver.isControl) {
            throw ParseError.badValue("giá trị chứa ký tự điều khiển")
        }
    }
}

/// Nguồn của một yêu cầu mở host.
public enum OpenOrigin: Equatable, Sendable {
    /// URL từ trình duyệt/app khác (không tin cậy).
    case external
    /// Có file yêu cầu hợp lệ do CLI ghi trong thư mục app.
    case cli

    /// Request id lạ/hết hạn/hỏng không phải CLI -> coi là external.
    public init(consumption: CLIOpenRequest.Outcome) {
        if case .valid = consumption { self = .cli } else { self = .external }
    }

    /// external luôn xác nhận; CLI hợp lệ chỉ xác nhận khi PROD.
    public func requiresConfirmation(environment: HostEnvironment) -> Bool {
        switch self {
        case .external: return true
        case .cli: return environment == .prod
        }
    }
}

/// Yêu cầu mở host đã giải xong từ URL, chưa chọn host.
public struct OpenIntent: Equatable, Sendable {
    public let reference: URLHostReference
    public let origin: OpenOrigin
}

public enum OpenURLFailure: Error, Equatable, CustomStringConvertible {
    case invalidURL(AppURLRequest.ParseError)
    /// `cli?request=` không có file hợp lệ: không có host nào để mở.
    case unknownCLIRequest

    public var description: String {
        switch self {
        case .invalidURL(let e): return e.description
        case .unknownCLIRequest: return "Yêu cầu từ CLI không còn hiệu lực (hết hạn hoặc không tồn tại)."
        }
    }
}

public enum OpenURLHandler {
    /// Phân tích URL; với `cli?request=` đọc và xoá file yêu cầu.
    public static func intent(for url: URL, requestsDirectory: URL, now: Date = Date()) -> Result<
        OpenIntent, OpenURLFailure
    > {
        let parsed: AppURLRequest
        do { parsed = try AppURLRequest.parse(url) } catch let e as AppURLRequest.ParseError {
            return .failure(.invalidURL(e))
        } catch { return .failure(.invalidURL(.badQuery("lỗi không rõ"))) }
        switch parsed {
        case .external(let ref):
            return .success(OpenIntent(reference: ref, origin: .external))
        case .fromCLI(let rid):
            let outcome = CLIOpenRequest.consume(id: rid, in: requestsDirectory, now: now)
            guard case .valid(let hostID) = outcome else { return .failure(.unknownCLIRequest) }
            return .success(OpenIntent(reference: .id(hostID), origin: OpenOrigin(consumption: outcome)))
        }
    }

    /// Chọn host đúng một kết quả (cùng quy tắc CLI, loại Windows).
    public static func host(for intent: OpenIntent, in hosts: [HostProfile]) throws -> HostProfile {
        switch intent.reference {
        case .id(let id): return try HostResolver.resolve(id: id, in: hosts)
        case .name(let n): return try HostResolver.resolve(n, in: hosts)
        }
    }

    /// Nội dung hộp xác nhận: tên, môi trường, user@host.
    public static func confirmationText(for host: HostProfile, origin: OpenOrigin) -> (title: String, message: String) {
        let target: String
        if host.connectionMode == .existingSSHConfigAlias, host.hostName.isEmpty {
            target = "alias \(host.sshConfigAlias ?? "?") (SSH config)"
        } else {
            target =
                (host.user.isEmpty ? "" : host.user + "@") + host.hostName
                + (host.port == 22 ? "" : ":\(host.port)")
        }
        let source = origin == .cli ? "Yêu cầu từ lệnh sshdesk" : "Yêu cầu từ liên kết bên ngoài"
        let prod = host.environment == .prod ? "\n\nĐây là máy PROD." : ""
        return (
            "Mở “\(HostResolver.printable(host.displayName))” trong Warp?",
            "\(source).\nMôi trường: \(host.environment.rawValue)\nKết nối: \(HostResolver.printable(target))\(prod)"
        )
    }
}
