import Foundation

public enum CredentialSetError: Error, Equatable, Sendable {
    /// Tên rỗng, quá 100 ký tự hoặc có ký tự điều khiển.
    case invalidName
    /// Đã có bộ khác trùng tên (không phân biệt hoa thường). Giá trị = tên đang có.
    case duplicateName(String)
    case notFound(UUID)
    case invalidUser(String)
    /// Đường dẫn key không hợp lệ (không tuyệt đối, có `%`, ký tự điều khiển...).
    case invalidIdentityFile
    case invalidIdentityAgent(IdentityAgentError)
    /// Chuỗi tự do chứa NUL/ký tự điều khiển không được phép. `field` là tên trường.
    case invalidField(field: String)
}

/// Bộ đăng nhập dùng chung (ADR-030). KHÔNG chứa secret: password nằm ở Keychain account `set-<uuid>`,
/// passphrase của key ở `setkey-<uuid>` (tham chiếu tất định, không lưu trong DB).
public struct CredentialSet: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// Gợi ý user; chỉ dùng khi host để trống user.
    public var user: String?
    /// Đường dẫn file key riêng (chỉ lưu đường dẫn, không bao giờ đọc nội dung).
    public var identityFile: String?
    /// Socket `IdentityAgent` (ADR-024).
    public var identityAgent: String?
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date

    public static let maxNameLength = 100
    public static let maxNoteLength = 2000

    public init(
        id: UUID = UUID(), name: String, user: String? = nil, identityFile: String? = nil,
        identityAgent: String? = nil, note: String = "", createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.user = user
        self.identityFile = identityFile
        self.identityAgent = identityAgent
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Tham chiếu Keychain tất định

    public static func passwordReference(for id: UUID) -> String { "set-" + id.uuidString.lowercased() }
    public static func passphraseReference(for id: UUID) -> String { "setkey-" + id.uuidString.lowercased() }

    public var passwordReference: String { Self.passwordReference(for: id) }
    public var passphraseReference: String { Self.passphraseReference(for: id) }

    // MARK: - Chuẩn hoá & kiểm tra

    /// Bỏ khoảng trắng hai đầu; 1–100 ký tự, không ký tự điều khiển.
    public static func normalizedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxNameLength, !hasControl(name) else {
            throw CredentialSetError.invalidName
        }
        return name
    }

    /// So tên không phân biệt hoa thường (và dấu) để tránh hai bộ tên gần giống nhau.
    public static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Trả bản đã chuẩn hoá (tên đã trim; user/key/agent rỗng → nil). Ném lỗi nếu có giá trị sai.
    public func validated() throws -> CredentialSet {
        var set = self
        set.name = try Self.normalizedName(name)
        set.user = Self.blankToNil(user)
        set.identityFile = Self.blankToNil(identityFile)
        set.identityAgent = Self.blankToNil(identityAgent)
        if let user = set.user {
            guard !Self.hasControl(user),
                user.range(of: #"^[A-Za-z0-9._][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
            else { throw CredentialSetError.invalidUser(user) }
        }
        if let file = set.identityFile {
            // Đúng validator IdentityFile của host/writer: tuyệt đối, không `%`, không ký tự điều khiển.
            do { try SSHConfigWriter.validatePath(file, field: "identityFile") } catch {
                throw CredentialSetError.invalidIdentityFile
            }
        }
        if let agent = set.identityAgent {
            do { try IdentityAgentPath.validate(agent) } catch let e as IdentityAgentError {
                throw CredentialSetError.invalidIdentityAgent(e)
            }
        }
        if set.note.unicodeScalars.contains(where: { $0.value == 0 }) || set.note.count > Self.maxNoteLength {
            throw CredentialSetError.invalidField(field: "note")
        }
        return set
    }

    /// Bản dùng để so sánh (chuỗi trắng → nil), không ném lỗi.
    public var normalizedForCompare: CredentialSet {
        var s = self
        s.identityFile = Self.blankToNil(identityFile)
        return s
    }

    private static func blankToNil(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.value == 0x7F }
    }

    // MARK: - Loại bộ (hiển thị)

    /// Các phần bộ đang có, theo thứ tự cố định. Rỗng → bộ trống.
    public func parts(hasPassword: Bool) -> [Part] {
        var result: [Part] = []
        if hasPassword { result.append(.password) }
        if identityFile != nil { result.append(.key) }
        if identityAgent != nil { result.append(.agent) }
        return result
    }

    public enum Part: String, Sendable, CaseIterable {
        case password = "Password"
        case key = "Key"
        case agent = "Agent"
    }

    /// "Password", "Key", "Password + Key", "Agent"... hoặc "Trống".
    public func kindLabel(hasPassword: Bool) -> String {
        let p = parts(hasPassword: hasPassword)
        return p.isEmpty ? "Trống" : p.map(\.rawValue).joined(separator: " + ")
    }
}

extension CredentialSet {
    /// Host `.keyFile` đang lấy key từ bộ này (không có key riêng) sẽ mất key nếu sửa bộ từ `before` sang `after`.
    public static func hostsLosingKey(hosts: [HostProfile], before: CredentialSet, after: CredentialSet)
        -> [HostProfile]
    {
        guard before.identityFile != nil, after.identityFile == nil else { return [] }
        return hosts.filter {
            $0.credentialSetID == before.id && $0.authMethod == .keyFile && ($0.identityFile ?? "").isEmpty
        }
    }
}
