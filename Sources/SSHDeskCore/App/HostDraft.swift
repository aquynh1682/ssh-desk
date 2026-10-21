import Foundation

/// Bản nháp của form hồ sơ: giữ chuỗi người dùng gõ, kiểm tra theo từng trường và dựng `HostProfile`.
/// Không đọc nội dung file key — chỉ giữ đường dẫn.
public struct HostDraft: Equatable, Sendable {
    public enum Field: Hashable, Sendable {
        case displayName, hostName, user, port, identityFile, password, jumpHost, alias, general
    }

    public var displayName = ""
    public var hostName = ""
    public var user = ""
    public var portText = "22"
    /// Lựa chọn "Xác thực" trên form (ADR-015). `.password` lưu thành `authMethod .interactive` + item Keychain.
    public enum AuthChoice: Hashable, Sendable {
        case agent, keyFile, password, prompt

        public var method: HostAuthMethod {
            switch self {
            case .agent: return .agent
            case .keyFile: return .keyFile
            case .password, .prompt: return .interactive
            }
        }

        public static func from(_ method: HostAuthMethod, hasSavedPassword: Bool) -> AuthChoice {
            switch method {
            case .agent: return .agent
            case .keyFile: return .keyFile
            case .interactive: return hasSavedPassword ? .password : .prompt
            }
        }
    }

    public var authChoice: AuthChoice = .agent
    public var authMethod: HostAuthMethod {
        get { authChoice.method }
        set { authChoice = .from(newValue, hasSavedPassword: false) }
    }
    public var identityFile = ""
    public var jumpHostID: UUID?
    public var project = ""
    public var environment: HostEnvironment = .other
    public var tagsText = ""
    public var notes = ""
    public var bookmarks: [RemoteBookmark] = []

    public init() {}

    public init(host: HostProfile, hasSavedPassword: Bool = false) {
        displayName = host.displayName
        hostName = host.hostName
        user = host.user
        portText = String(host.port)
        authChoice = .from(host.authMethod, hasSavedPassword: hasSavedPassword)
        identityFile = host.identityFile ?? ""
        jumpHostID = host.jumpHostID
        project = host.project
        environment = host.environment
        tagsText = host.tags.joined(separator: ", ")
        notes = host.notes
        bookmarks = host.remoteBookmarks
    }

    public static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Dựng hồ sơ từ bản nháp. Với `base` (sửa), giữ id, favorite, thời gian, credentialReference...
    /// Hồ sơ imported chỉ nhận metadata; cấu hình kết nối giữ nguyên từ `base`.
    public func profile(basedOn base: HostProfile?) -> HostProfile {
        var h = base ?? HostProfile(displayName: displayName)
        h.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        h.project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        h.environment = environment
        h.tags = Self.parseTags(tagsText)
        h.notes = notes
        h.remoteBookmarks = bookmarks.filter { !$0.name.isEmpty || !$0.path.isEmpty }
        if h.connectionMode == .existingSSHConfigAlias { return h }
        h.connectionMode = .managed
        h.hostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        h.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        h.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
        h.authMethod = authChoice.method
        h.identityFile = authChoice == .keyFile ? identityFile : nil
        h.jumpHostID = jumpHostID
        return h
    }

    /// Lỗi theo trường (tiếng Việt). Rỗng = hợp lệ.
    /// - hasSavedPassword: hồ sơ đang có mật khẩu trong Keychain.
    /// - passwordEntered: người dùng đã gõ mật khẩu mới.
    public func errors(
        basedOn base: HostProfile?, hasSavedPassword: Bool = false, passwordEntered: Bool = false
    ) -> [Field: String] {
        var result: [Field: String] = [:]
        let isImported = base?.connectionMode == .existingSSHConfigAlias
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result[.displayName] = "Tên không được để trống."
        }
        if !isImported {
            let p = portText.trimmingCharacters(in: .whitespaces)
            if Int(p) == nil || !(1...65535).contains(Int(p) ?? 0) {
                result[.port] = "Cổng phải là số từ 1 đến 65535."
            }
            if hostName.trimmingCharacters(in: .whitespaces).isEmpty {
                result[.hostName] = "Cần nhập địa chỉ máy chủ."
            }
            if user.trimmingCharacters(in: .whitespaces).isEmpty {
                result[.user] = "Cần nhập tên người dùng."
            }
            if authChoice == .keyFile && identityFile.isEmpty {
                result[.identityFile] = "Hãy chọn file khoá riêng."
            }
        }
        if authChoice == .password && !hasSavedPassword && !passwordEntered {
            result[.password] = "Nhập mật khẩu."
        }
        // Các quy tắc còn lại (ký tự cấm, newline...) lấy từ validate() của model.
        if result.isEmpty {
            do { try profile(basedOn: base).validate() } catch let e as HostValidationError {
                let (f, m) = Self.describe(e)
                result[f] = m
            } catch { result[.general] = "Dữ liệu không hợp lệ." }
        }
        return result
    }

    /// Có cần xoá mật khẩu đã lưu khi lưu không: đang có item Keychain mà người dùng chọn kiểu khác "Mật khẩu".
    public func removesStoredPassword(hasSavedPassword: Bool) -> Bool {
        hasSavedPassword && authChoice != .password
    }

    public static func describe(_ e: HostValidationError) -> (Field, String) {
        switch e {
        case .emptyDisplayName: return (.displayName, "Tên không được để trống.")
        case .invalidHostName: return (.hostName, "Địa chỉ máy chủ chứa ký tự không hợp lệ.")
        case .invalidUser:
            return (.user, "Tên người dùng chỉ gồm chữ, số, '.', '_', '-' và không bắt đầu bằng '-'.")
        case .invalidPort: return (.port, "Cổng phải là số từ 1 đến 65535.")
        case .identityFileRequired: return (.identityFile, "Hãy chọn file khoá riêng.")
        case .invalidIdentityFile:
            return (.identityFile, "Đường dẫn khoá phải tuyệt đối, không chứa '%' hay ký tự điều khiển.")
        case .invalidAlias: return (.alias, "Alias không hợp lệ.")
        case .invalidSSHConfigPath: return (.alias, "Đường dẫn file SSH config không hợp lệ.")
        case .containsNUL(let f): return (.general, "Trường \(f) chứa ký tự không hợp lệ.")
        case .selfJump: return (.jumpHost, "Máy không thể là bastion của chính nó.")
        case .jumpHostNotAllowed: return (.jumpHost, "Hồ sơ alias có sẵn không dùng bastion của app.")
        }
    }
}
