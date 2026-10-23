import Foundation

/// Nơi lưu password vừa nhập ở sheet "Nhập mật khẩu" (ADR-029 + ADR-030).
public enum PasswordSaveChoice: Equatable, Sendable {
    /// "Chỉ lưu cho máy này": mật khẩu riêng của host.
    case thisHostOnly
    /// "Dùng bộ đăng nhập có sẵn": kiểm bằng password của bộ, không nhập lại.
    case existingSet(UUID)
    /// "Lưu thành bộ mới: [tên]": tạo bộ, lưu password vào bộ, gán host.
    case newSet(name: String)
}

public enum PasswordEntryResult: Equatable, Sendable {
    /// Đã kiểm tra (hoặc người dùng chọn "Vẫn lưu") và lưu; kèm host mới nhất.
    case saved(HostProfile)
    case wrongPassword
    /// Password của bộ không đúng với máy này. KHÔNG ghi đè bộ.
    case setPasswordWrong(setID: UUID, setName: String, affectedHosts: Int)
    /// Không thử tiếp được và không lưu: host key chưa xác nhận/đổi, OTP/MFA/passphrase.
    case blocked(PasswordVerification)
    /// Lỗi mạng/timeout: hỏi "Không kiểm tra được. Vẫn lưu?" (mặc định Không).
    case unverifiable(PasswordVerification)
    /// Đầu vào không hợp lệ (tên bộ trùng/sai, bộ chưa có mật khẩu...). Thông báo cho người dùng.
    case invalid(String)
    case failed(String)
}

/// Luồng "kiểm tra rồi mới lưu" của sheet hỏi mật khẩu (ADR-029/030). Logic thuần Core; UI chỉ gọi vào đây.
/// Password đi qua biến cục bộ, không log.
public struct PasswordEntryService: Sendable {
    private let connection: ConnectionService
    private let verifier: any PasswordVerifying
    private let credentials: any CredentialStore

    public init(
        connection: ConnectionService, verifier: any PasswordVerifying, credentials: any CredentialStore
    ) {
        self.connection = connection
        self.verifier = verifier
        self.credentials = credentials
    }

    /// Kiểm tra đăng nhập rồi lưu theo `choice`. Không đụng gì khi kiểm tra không đạt.
    public func save(hostID: UUID, password: String, choice: PasswordSaveChoice) async -> PasswordEntryResult {
        do {
            guard let host = try await connection.repository.host(id: hostID) else {
                return .failed("Không tìm thấy máy.")
            }
            let prepared = try await prepare(host: host, password: password, choice: choice)
            guard case .secret(let secret) = prepared else {
                if case .rejected(let result) = prepared { return result }
                return .failed("Lỗi nội bộ.")
            }
            try await connection.regenerateSSHConfig()
            let outcome = await verifier.verify(host: host, password: secret)
            switch outcome {
            case .ok:
                return await commit(host: host, password: password, choice: choice)
            case .wrongPassword:
                if case .existingSet(let id) = choice {
                    let name = (try? await connection.repository.credentialSet(id: id))?.name ?? ""
                    let affected = await affectedHosts(setID: id, host: host)
                    return .setPasswordWrong(setID: id, setName: name, affectedHosts: affected)
                }
                return .wrongPassword
            case .hostKeyUnconfirmed, .hostKeyChanged, .otherPrompt:
                return .blocked(outcome)
            case .networkError, .timeout:
                return .unverifiable(outcome)
            }
        } catch {
            return .failed("\(error)")
        }
    }

    /// Người dùng đã trả lời "Vẫn lưu" sau `.unverifiable`: lưu không kiểm tra.
    public func saveWithoutVerifying(hostID: UUID, password: String, choice: PasswordSaveChoice) async
        -> PasswordEntryResult
    {
        do {
            guard let host = try await connection.repository.host(id: hostID) else {
                return .failed("Không tìm thấy máy.")
            }
            let prepared = try await prepare(host: host, password: password, choice: choice)
            if case .rejected(let result) = prepared { return result }
            return await commit(host: host, password: password, choice: choice)
        } catch {
            return .failed("\(error)")
        }
    }

    /// "Cập nhật mật khẩu của bộ (ảnh hưởng N máy)": người dùng nhập password MỚI và đã xác nhận rõ.
    /// Kiểm tra password mới với máy này trước; chỉ đúng mới ghi đè password của bộ và gán máy vào bộ.
    public func updateSetPassword(hostID: UUID, setID: UUID, newPassword: String) async
        -> PasswordEntryResult
    {
        do {
            guard !newPassword.isEmpty else { return .invalid("Nhập mật khẩu mới của bộ.") }
            guard let host = try await connection.repository.host(id: hostID) else {
                return .failed("Không tìm thấy máy.")
            }
            guard (try await connection.repository.credentialSet(id: setID)) != nil else {
                return .invalid("Bộ đăng nhập không còn tồn tại.")
            }
            try await connection.regenerateSSHConfig()
            let outcome = await verifier.verify(host: host, password: newPassword)
            switch outcome {
            case .ok:
                try await connection.saveSetPassword(setID: setID, password: newPassword)
                return await assign(host: host, setID: setID)
            case .wrongPassword: return .wrongPassword
            case .hostKeyUnconfirmed, .hostKeyChanged, .otherPrompt: return .blocked(outcome)
            case .networkError, .timeout: return .unverifiable(outcome)
            }
        } catch {
            return .failed("\(error)")
        }
    }

    // MARK: - Nội bộ

    private enum Prepared {
        case secret(String)
        case rejected(PasswordEntryResult)
    }

    /// Kiểm tra đầu vào và trả password cần dùng để thử đăng nhập (với bộ có sẵn = password của bộ).
    private func prepare(host: HostProfile, password: String, choice: PasswordSaveChoice) async throws
        -> Prepared
    {
        switch choice {
        case .thisHostOnly:
            guard !password.isEmpty else { return .rejected(.invalid("Nhập mật khẩu.")) }
            return .secret(password)
        case .newSet(let name):
            guard !password.isEmpty else { return .rejected(.invalid("Nhập mật khẩu.")) }
            let normalized: String
            do { normalized = try CredentialSet.normalizedName(name) } catch {
                return .rejected(.invalid("Tên bộ phải có 1–100 ký tự, không có ký tự điều khiển."))
            }
            let existing = try await connection.repository.credentialSets()
            if existing.contains(where: { CredentialSet.sameName($0.name, normalized) }) {
                return .rejected(.invalid("Đã có bộ đăng nhập tên “\(normalized)”."))
            }
            return .secret(password)
        case .existingSet(let id):
            guard let set = try await connection.repository.credentialSet(id: id) else {
                return .rejected(.invalid("Bộ đăng nhập không còn tồn tại."))
            }
            guard credentials.status(ref: set.passwordReference) == .present,
                let setPassword = credentials.read(ref: set.passwordReference), !setPassword.isEmpty
            else {
                return .rejected(.invalid("Bộ “\(set.name)” chưa có mật khẩu dùng được."))
            }
            return .secret(setPassword)
        }
    }

    private func commit(host: HostProfile, password: String, choice: PasswordSaveChoice) async
        -> PasswordEntryResult
    {
        do {
            switch choice {
            case .thisHostOnly:
                return .saved(try await connection.savePassword(hostID: host.id, password: password))
            case .existingSet(let id):
                return await assign(host: host, setID: id)
            case .newSet(let name):
                let created = try await connection.createCredentialSet(
                    CredentialSet(name: name), password: password)
                let result = await assign(host: host, setID: created.id)
                if case .saved = result { return result }
                _ = try? await connection.deleteCredentialSet(id: created.id)
                return result
            }
        } catch let error as CredentialSetError {
            if case .duplicateName(let n) = error { return .invalid("Đã có bộ đăng nhập tên “\(n)”.") }
            return .failed("\(error)")
        } catch {
            return .failed("\(error)")
        }
    }

    /// Gán host vào bộ (gán bằng tay: không hold). Mật khẩu riêng đang hỏng của host bị gỡ vì nó ưu tiên hơn bộ.
    private func assign(host: HostProfile, setID: UUID) async -> PasswordEntryResult {
        do {
            if let own = host.credentialReference, !own.isEmpty,
                credentials.status(ref: own) != .present
            {
                try await connection.clearPassword(hostID: host.id)
            }
            _ = try await connection.assignCredentialSet(setID: setID, to: [host.id])
            guard let fresh = try await connection.repository.host(id: host.id) else {
                return .failed("Không tìm thấy máy.")
            }
            return .saved(fresh)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Số máy bị ảnh hưởng khi đổi password của bộ: các máy đang dùng bộ, cộng máy này nếu chưa thuộc bộ.
    public func affectedHosts(setID: UUID, host: HostProfile) async -> Int {
        let usage = (try? await connection.repository.credentialSetUsage())?[setID] ?? 0
        return usage + (host.credentialSetID == setID ? 0 : 1)
    }
}
