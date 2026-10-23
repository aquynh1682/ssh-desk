import Foundation

public enum MetricsSourceKind: String, Sendable, CaseIterable, Equatable {
    case prometheus
    case zabbix

    public var title: String {
        switch self {
        case .prometheus: return "Prometheus"
        case .zabbix: return "Zabbix"
        }
    }

    /// Mẫu instance mặc định: node_exporter lắng nghe 9100; Zabbix khớp theo tên host.
    public var defaultInstanceTemplate: String {
        switch self {
        case .prometheus: return "{{hostName}}:9100"
        case .zabbix: return "{{hostName}}"
        }
    }
}

public enum MetricsAuthKind: String, Sendable, CaseIterable, Equatable {
    case none
    case bearer
    case basic

    public var title: String {
        switch self {
        case .none: return "Không xác thực"
        case .bearer: return "Bearer token"
        case .basic: return "Basic (user + password)"
        }
    }
}

public enum MetricsSourceError: Error, Equatable, LocalizedError {
    case emptyName
    case nameInvalid
    case urlInvalid(String)
    case templateInvalid(String)
    case basicUserInvalid
    /// http (không phải loopback) có token/password mà chưa tick "tôi hiểu".
    case insecureHTTPNotAcknowledged
    case zabbixBasicUnsupported
    case secretRequired
    case secretInvalid
    case secretReenterRequired
    case notFound(UUID)
    case credentialsUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Tên nguồn không được để trống."
        case .nameInvalid: return "Tên nguồn quá dài (tối đa 100) hoặc có ký tự điều khiển."
        case .urlInvalid(let why): return "URL không hợp lệ: \(why)"
        case .templateInvalid(let why): return "Mẫu instance không hợp lệ: \(why)"
        case .basicUserInvalid:
            return "Tên đăng nhập Basic không được rỗng, không chứa ':' hay ký tự điều khiển."
        case .insecureHTTPNotAcknowledged:
            return
                "http không mã hoá: token/password sẽ gửi dạng rõ. Tick “Tôi hiểu token gửi không mã hoá” hoặc dùng https."
        case .zabbixBasicUnsupported:
            return "Zabbix chỉ hỗ trợ token API (Bearer), không hỗ trợ user/password."
        case .secretRequired: return "Cần nhập token/password cho kiểu xác thực này."
        case .secretReenterRequired:
            return "Đổi URL/kiểu xác thực — hãy nhập lại token/mật khẩu."
        case .secretInvalid: return "Token/password có ký tự điều khiển hoặc khoảng trắng không hợp lệ."
        case .notFound: return "Không tìm thấy nguồn số liệu."
        case .credentialsUnavailable: return "Không có kho bí mật để lưu token/password."
        }
    }
}

/// Nguồn số liệu Prometheus/Zabbix (ADR-028). Không chứa secret: token/password nằm trong `CredentialStore`
/// dưới account `credentialRef`.
public struct MetricsSource: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: MetricsSourceKind
    public var baseURL: String
    public var authKind: MetricsAuthKind
    /// Chỉ dùng khi `authKind == .basic`.
    public var basicUser: String?
    public var instanceTemplate: String
    public var allowInsecureHTTP: Bool
    public var createdAt: Date

    public static let maxURLLength = 2048
    public static let maxNameLength = 100
    public static let maxTemplateLength = 256

    public init(
        id: UUID = UUID(), name: String, kind: MetricsSourceKind, baseURL: String,
        authKind: MetricsAuthKind = .none, basicUser: String? = nil,
        instanceTemplate: String? = nil, allowInsecureHTTP: Bool = false, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.authKind = authKind
        self.basicUser = basicUser
        self.instanceTemplate = instanceTemplate ?? kind.defaultInstanceTemplate
        self.allowInsecureHTTP = allowInsecureHTTP
        self.createdAt = createdAt
    }

    public static func secretReference(for id: UUID) -> String {
        "metrics-" + id.uuidString.lowercased()
    }

    /// Account trong `CredentialStore`; nil khi không cần secret.
    public var credentialRef: String? {
        authKind == .none ? nil : Self.secretReference(for: id)
    }

    public var usesHTTP: Bool { urlComponents?.scheme?.lowercased() == "http" }

    /// Cùng origin (scheme + host + port) và cùng kiểu xác thực -> secret cũ vẫn dùng được.
    public func sharesSecretScope(with other: MetricsSource) -> Bool {
        guard authKind == other.authKind, basicUser == other.basicUser,
            let a = urlComponents, let b = other.urlComponents
        else { return false }
        func origin(_ c: URLComponents) -> String {
            "\(c.scheme?.lowercased() ?? "")://\(c.host?.lowercased() ?? ""):\(c.port.map(String.init) ?? "")"
        }
        return origin(a) == origin(b)
    }

    var urlComponents: URLComponents? { URLComponents(string: baseURL) }

    /// http tới máy không phải loopback và có gửi secret -> cần tick đồng ý (cũng dùng để cảnh báo trên UI).
    public var sendsSecretOverInsecureHTTP: Bool {
        guard usesHTTP, authKind != .none else { return false }
        return !MetricsURLRules.isLoopback(host: urlComponents?.host)
    }

    // MARK: - Kiểm tra

    /// Chuẩn hoá + kiểm tra mọi trường. Ném `MetricsSourceError` đầu tiên gặp.
    public func validated() throws -> MetricsSource {
        var s = self
        s.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.name.isEmpty else { throw MetricsSourceError.emptyName }
        guard s.name.count <= Self.maxNameLength, !MetricsURLRules.hasControl(s.name) else {
            throw MetricsSourceError.nameInvalid
        }
        s.baseURL = try MetricsURLRules.normalizedBaseURL(baseURL)
        s.instanceTemplate = instanceTemplate.trimmingCharacters(in: .whitespaces)
        try InstanceTemplate.validate(s.instanceTemplate)

        switch s.authKind {
        case .none, .bearer:
            s.basicUser = nil
        case .basic:
            guard kind == .prometheus else { throw MetricsSourceError.zabbixBasicUnsupported }
            let user = (basicUser ?? "").trimmingCharacters(in: .whitespaces)
            guard !user.isEmpty, !user.contains(":"), !MetricsURLRules.hasControl(user), user.count <= 256
            else { throw MetricsSourceError.basicUserInvalid }
            s.basicUser = user
        }
        if s.sendsSecretOverInsecureHTTP, !s.allowInsecureHTTP {
            throw MetricsSourceError.insecureHTTPNotAcknowledged
        }
        return s
    }
}

/// Quy tắc URL/chuỗi thuần.
public enum MetricsURLRules {
    /// C0, DEL, C1.
    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || ($0.value >= 0x80 && $0.value <= 0x9F) }
    }

    public static func isLoopback(host: String?) -> Bool {
        guard var h = host?.lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" { return true }
        return IPLiteral(h)?.isLoopback ?? false
    }

    /// Trả URL chuẩn hoá (scheme thường, bỏ `/` thừa ở cuối). Chỉ http/https, không userinfo/query/fragment.
    public static func normalizedBaseURL(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MetricsSourceError.urlInvalid("để trống") }
        guard text.count <= MetricsSource.maxURLLength else {
            throw MetricsSourceError.urlInvalid("dài quá \(MetricsSource.maxURLLength) ký tự")
        }
        guard !hasControl(text), !text.unicodeScalars.contains(where: { $0 == " " }) else {
            throw MetricsSourceError.urlInvalid("có khoảng trắng hoặc ký tự điều khiển")
        }
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased() else {
            throw MetricsSourceError.urlInvalid("thiếu http:// hoặc https://")
        }
        guard scheme == "https" || scheme == "http" else {
            throw MetricsSourceError.urlInvalid("chỉ hỗ trợ http và https")
        }
        guard c.user == nil, c.password == nil, !text.contains("@") else {
            throw MetricsSourceError.urlInvalid("không được chứa user:password trong URL")
        }
        guard c.query == nil, c.fragment == nil, !text.contains("?"), !text.contains("#") else {
            throw MetricsSourceError.urlInvalid("không được có query hoặc fragment")
        }
        guard let host = c.host, !host.isEmpty else {
            throw MetricsSourceError.urlInvalid("thiếu tên máy")
        }
        _ = host
        c.scheme = scheme
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        c.percentEncodedPath = path
        guard let out = c.string, out.count <= MetricsSource.maxURLLength else {
            throw MetricsSourceError.urlInvalid("không đọc được")
        }
        return out
    }
}

/// Mẫu nhãn instance: chỉ `{{hostName}}` và `{{port}}` (ADR-028).
public enum InstanceTemplate {
    public static let placeholders: Set<String> = ["hostName", "port"]

    enum Piece: Equatable {
        case literal(String)
        case placeholder(String)
    }

    static func parse(_ template: String) throws -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(template)
        var literal = ""
        while !rest.isEmpty {
            if rest.hasPrefix("{{") {
                guard let end = rest.range(of: "}}") else {
                    throw MetricsSourceError.templateInvalid("thiếu '}}'")
                }
                let name = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])
                guard placeholders.contains(name) else {
                    throw MetricsSourceError.templateInvalid("chỉ cho phép {{hostName}} và {{port}}")
                }
                if !literal.isEmpty {
                    pieces.append(.literal(literal))
                    literal = ""
                }
                pieces.append(.placeholder(name))
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("}}") {
                throw MetricsSourceError.templateInvalid("'}}' thừa")
            } else {
                literal.append(rest.removeFirst())
            }
        }
        if !literal.isEmpty { pieces.append(.literal(literal)) }
        return pieces
    }

    public static func validate(_ template: String) throws {
        guard !template.isEmpty else { throw MetricsSourceError.templateInvalid("để trống") }
        guard template.count <= MetricsSource.maxTemplateLength else {
            throw MetricsSourceError.templateInvalid("dài quá \(MetricsSource.maxTemplateLength) ký tự")
        }
        guard !MetricsURLRules.hasControl(template) else {
            throw MetricsSourceError.templateInvalid("có ký tự điều khiển")
        }
        _ = try parse(template)
    }

    /// Thay placeholder bằng giá trị thật (chưa escape PromQL). Kết quả cấm ký tự điều khiển.
    public static func render(_ template: String, hostName: String, port: Int) throws -> String {
        let host = hostName.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw MetricsSourceError.templateInvalid("máy chưa có địa chỉ (hostName)") }
        var out = ""
        for piece in try parse(template) {
            switch piece {
            case .literal(let s): out += s
            case .placeholder("hostName"): out += host
            case .placeholder: out += String(port)
            }
        }
        guard !MetricsURLRules.hasControl(out), out.count <= 512 else {
            throw MetricsSourceError.templateInvalid("giá trị sau khi thay có ký tự điều khiển hoặc quá dài")
        }
        return out
    }
}

/// Escape giá trị nhãn trong chuỗi PromQL `"..."`: `\` -> `\\`, `"` -> `\"`, newline -> `\n`.
public enum PromQL {
    public static func escapeLabelValue(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
