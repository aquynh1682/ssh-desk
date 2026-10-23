import Foundation

/// Bản nháp của form hồ sơ: giữ chuỗi người dùng gõ, kiểm tra theo từng trường và dựng `HostProfile`.
/// Không đọc nội dung file key — chỉ giữ đường dẫn.
public struct HostDraft: Equatable, Sendable {
    public enum Field: Hashable, Sendable {
        case displayName, hostName, user, port, rdpUser, rdpDomain, rdpGateway, identityFile, identityAgent, password,
            jumpHost, alias,
            general
    }

    public var kind: HostKind = .ssh
    public var rdpUsername = ""
    public var rdpDomain = ""
    public var rdpGateway = ""
    public var rdpScreenMode: RDPScreenMode = .fullScreen
    public var rdpMultiMonitor = false
    public var rdpRedirectClipboard = true
    public var rdpAdminSession = false

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
    /// Agent (ADR-024): nil = theo mặc định trong Cài đặt; `.custom` dùng `identityAgentCustom`.
    public var identityAgentPreset: IdentityAgentPreset?
    public var identityAgentCustom = ""
    public var jumpHostID: UUID?
    /// Bộ đăng nhập dùng chung (ADR-030). Chỉ có hiệu lực khi xác thực là Mật khẩu / File khoá.
    public var credentialSetID: UUID?
    public var project = ""
    public var environment: HostEnvironment = .other
    public var tagsText = ""
    public var notes = ""
    public var bookmarks: [RemoteBookmark] = []

    public init() {}

    /// Máy MỚI: lấy mặc định Windows App từ Cài đặt (ADR-021). Không dùng cho sửa/nhân bản.
    public init(newHostDefaults settings: AppSettings) {
        rdpScreenMode = settings.rdpFullScreen ? .fullScreen : .window
        rdpMultiMonitor = settings.rdpMultiMonitor
        rdpRedirectClipboard = settings.rdpRedirectClipboard
    }

    /// Đổi loại máy; chuyển cổng mặc định (22 <-> 3389) nếu người dùng chưa sửa cổng.
    public mutating func setKind(_ newKind: HostKind) {
        guard newKind != kind else { return }
        let p = portText.trimmingCharacters(in: .whitespaces)
        if newKind == .windowsRDP && p == "22" { portText = String(HostProfile.defaultRDPPort) }
        if newKind == .ssh && p == String(HostProfile.defaultRDPPort) { portText = "22" }
        // Máy Windows chỉ có 2 lựa chọn xác thực: Mật khẩu / Nhập trong Windows App. Mật khẩu được giữ.
        if newKind == .windowsRDP && authChoice != .password { authChoice = .prompt }
        if newKind == .ssh && authChoice == .prompt && kind == .windowsRDP { authChoice = .agent }
        kind = newKind
    }

    public init(host: HostProfile, hasSavedPassword: Bool = false) {
        kind = host.kind
        rdpUsername = host.rdpUsername
        rdpDomain = host.rdpDomain ?? ""
        rdpGateway = host.rdpGateway ?? ""
        rdpScreenMode = host.rdpScreenMode
        rdpMultiMonitor = host.rdpMultiMonitor
        rdpRedirectClipboard = host.rdpRedirectClipboard
        rdpAdminSession = host.rdpAdminSession
        displayName = host.displayName
        hostName = host.hostName
        user = host.user
        portText = String(host.port)
        authChoice =
            host.kind == .windowsRDP
            ? (hasSavedPassword || host.credentialSetID != nil ? .password : .prompt)
            : .from(host.authMethod, hasSavedPassword: hasSavedPassword || host.credentialSetID != nil)
        identityFile = host.identityFile ?? ""
        if let agent = host.identityAgent {
            let preset = IdentityAgentPreset.matching(agent)
            identityAgentPreset = preset
            if preset == .custom { identityAgentCustom = agent }
        }
        jumpHostID = host.jumpHostID
        credentialSetID = host.credentialSetID
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
        h.kind = kind
        if kind == .windowsRDP {
            h.connectionMode = .managed
            h.hostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            h.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
            h.rdpUsername = rdpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            let domain = rdpDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            h.rdpDomain = domain.isEmpty ? nil : domain
            let gateway = rdpGateway.trimmingCharacters(in: .whitespacesAndNewlines)
            h.rdpGateway = gateway.isEmpty ? nil : gateway
            h.rdpScreenMode = rdpScreenMode
            h.rdpMultiMonitor = rdpMultiMonitor
            h.rdpRedirectClipboard = rdpRedirectClipboard
            h.rdpAdminSession = rdpAdminSession
            // Trường SSH không dùng. credentialReference giữ nguyên để form xoá item Keychain khi lưu.
            // Mật khẩu Windows: `.interactive` + credentialReference (ADR-018); ngược lại `.agent` như trước.
            h.user = ""
            h.authMethod = authChoice == .password ? .interactive : .agent
            h.identityFile = nil
            h.identityAgent = nil
            h.jumpHostID = nil
            h.remoteBookmarks = []
            h.credentialSetID = authChoice == .password ? credentialSetID : nil
            return h
        }
        h.connectionMode = .managed
        h.hostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        h.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        h.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
        h.authMethod = authChoice.method
        h.identityFile = authChoice == .keyFile && !identityFile.isEmpty ? identityFile : nil
        h.identityAgent = identityAgentValue
        h.jumpHostID = jumpHostID
        h.credentialSetID = usesCredentialSet ? credentialSetID : nil
        return h
    }

    /// Picker "Bộ đăng nhập" chỉ hiện với Mật khẩu / File khoá (SSH) và Mật khẩu (Windows).
    public var usesCredentialSet: Bool {
        switch authChoice {
        case .password: return true
        case .keyFile: return kind == .ssh
        case .agent, .prompt: return false
        }
    }

    /// Cảnh báo (không chặn, không tự sửa): user của host khác user gợi ý của bộ (ADR-030). Windows không áp dụng.
    public func userMismatchWarning(for set: CredentialSet?) -> String? {
        guard kind == .ssh, let set, let hint = set.user else { return nil }
        let typed = user.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, typed != hint else { return nil }
        return "User của máy (\(typed)) khác user gợi ý của bộ “\(set.name)” (\(hint)). App không tự sửa."
    }

    /// Giá trị `IdentityAgent` sẽ lưu cho host managed SSH; nil = theo mặc định.
    public var identityAgentValue: String? {
        switch identityAgentPreset {
        case nil: return nil
        case .custom?: return identityAgentCustom.trimmingCharacters(in: .whitespacesAndNewlines)
        case let preset?: return preset.path
        }
    }

    /// Lỗi theo trường (tiếng Việt). Rỗng = hợp lệ.
    /// - hasSavedPassword: hồ sơ đang có mật khẩu trong Keychain.
    /// - passwordEntered: người dùng đã gõ mật khẩu mới.
    /// - credentialSet / setHasPassword: bộ đăng nhập đã chọn (ADR-030) và bộ đó đã có password chưa.
    public func errors(
        basedOn base: HostProfile?, hasSavedPassword: Bool = false, passwordEntered: Bool = false,
        credentialSet: CredentialSet? = nil, setHasPassword: Bool = false
    ) -> [Field: String] {
        let set = usesCredentialSet ? credentialSet : nil
        var result: [Field: String] = [:]
        let isImported = base?.connectionMode == .existingSSHConfigAlias
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result[.displayName] = "Tên không được để trống."
        }
        if kind == .windowsRDP && !isImported {
            let p = portText.trimmingCharacters(in: .whitespaces)
            if Int(p) == nil || !(1...65535).contains(Int(p) ?? 0) {
                result[.port] = "Cổng phải là số từ 1 đến 65535."
            }
            if hostName.trimmingCharacters(in: .whitespaces).isEmpty {
                result[.hostName] = "Cần nhập địa chỉ máy chủ."
            }
        } else if !isImported {
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
            if authChoice == .keyFile && identityFile.isEmpty && (set?.identityFile ?? "").isEmpty {
                result[.identityFile] = "Hãy chọn file khoá riêng."
            }
        }
        // Có bộ đăng nhập thì không bắt nhập mật khẩu riêng (bộ có thể được điền mật khẩu sau).
        if authChoice == .password && !hasSavedPassword && !passwordEntered && set == nil {
            result[.password] = "Nhập mật khẩu."
        }
        // Các quy tắc còn lại (ký tự cấm, newline...) lấy từ validate() của model.
        if result.isEmpty {
            do { try profile(basedOn: base).validate(credentialSet: set) } catch let e as HostValidationError {
                let (f, m) = Self.describe(e)
                result[f] = m
            } catch { result[.general] = "Dữ liệu không hợp lệ." }
        }
        return result
    }

    /// Có cần xoá mật khẩu đã lưu khi lưu không: đang có item Keychain mà người dùng chọn kiểu khác "Mật khẩu"
    /// (áp dụng cho cả SSH và Windows; đổi loại máy mà vẫn chọn Mật khẩu thì giữ).
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
        case .invalidIdentityAgent:
            return (
                .identityAgent,
                "Đường dẫn agent phải bắt đầu bằng '/' hoặc '~/' (hoặc SSH_AUTH_SOCK), tối đa 1024 byte, không chứa '%', '$' hay ký tự điều khiển."
            )
        case .invalidAlias: return (.alias, "Alias không hợp lệ.")
        case .invalidSSHConfigPath: return (.alias, "Đường dẫn file SSH config không hợp lệ.")
        case .containsNUL(let f): return (.general, "Trường \(f) chứa ký tự không hợp lệ.")
        case .selfJump: return (.jumpHost, "Máy không thể là bastion của chính nó.")
        case .jumpHostNotAllowed: return (.jumpHost, "Hồ sơ alias có sẵn không dùng bastion của app.")
        case .invalidRDPField(let f):
            let field: Field =
                f == "rdpDomain" ? .rdpDomain : (f == "rdpGateway" ? .rdpGateway : .rdpUser)
            return (field, "Giá trị không được chứa ký tự điều khiển và tối đa \(HostProfile.maxRDPFieldLength) ký tự.")
        case .invalidRDPGateway:
            return (.rdpGateway, "RD Gateway phải có dạng tên-máy hoặc tên-máy:cổng.")
        }
    }
}
