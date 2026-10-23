import Foundation

/// Quản lý nguồn số liệu: DB + bí mật (ADR-028/004b). Token/password chỉ đi vào `CredentialStore`.
public struct MetricSourceService: Sendable {
    public let repository: MetricSourceRepository
    private let credentials: (any CredentialStore)?

    public init(repository: MetricSourceRepository, credentials: (any CredentialStore)?) {
        self.repository = repository
        self.credentials = credentials
    }

    /// Token Bearer: ASCII in được, không khoảng trắng. Password Basic: không ký tự điều khiển.
    static func validateSecret(_ secret: String, kind: MetricsAuthKind) throws {
        guard !secret.isEmpty, secret.utf8.count <= 4096, !MetricsURLRules.hasControl(secret) else {
            throw MetricsSourceError.secretInvalid
        }
        if kind == .bearer {
            guard secret.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
                throw MetricsSourceError.secretInvalid
            }
        }
    }

    /// Tạo nguồn. Kiểm tra hợp lệ (gồm cờ http) TRƯỚC khi chạm kho bí mật.
    @discardableResult
    public func create(_ source: MetricsSource, secret: String?) throws -> MetricsSource {
        let valid = try source.validated()
        guard let ref = valid.credentialRef else { return try repository.insert(valid) }
        guard let credentials else { throw MetricsSourceError.credentialsUnavailable }
        guard let secret, !secret.isEmpty else { throw MetricsSourceError.secretRequired }
        try Self.validateSecret(secret, kind: valid.authKind)
        try credentials.save(ref: ref, password: secret)
        do { return try repository.insert(valid) } catch {
            try? credentials.delete(ref: ref)
            throw error
        }
    }

    /// Sửa nguồn. `secret == nil` = giữ bí mật hiện có (phải còn). Đổi sang `none` -> xoá bí mật.
    @discardableResult
    public func update(_ source: MetricsSource, secret: String?) throws -> MetricsSource {
        let valid = try source.validated()
        guard try repository.source(id: valid.id) != nil else { throw MetricsSourceError.notFound(valid.id) }
        let ref = MetricsSource.secretReference(for: valid.id)
        if valid.credentialRef != nil {
            guard let credentials else { throw MetricsSourceError.credentialsUnavailable }
            if let secret, !secret.isEmpty {
                try Self.validateSecret(secret, kind: valid.authKind)
                try credentials.save(ref: ref, password: secret)
            } else {
                // Giữ secret cũ chỉ khi URL (origin) và kiểu xác thực không đổi: tránh gửi token cũ tới nơi mới.
                if let stored = try repository.source(id: valid.id), !stored.sharesSecretScope(with: valid) {
                    throw MetricsSourceError.secretReenterRequired
                }
                guard let existing = credentials.read(ref: ref) else {
                    throw MetricsSourceError.secretRequired
                }
                try Self.validateSecret(existing, kind: valid.authKind)
            }
            return try repository.update(valid)
        }
        // Không còn cần bí mật.
        let saved = try repository.update(valid)
        try? credentials?.delete(ref: ref)
        return saved
    }

    /// Xoá nguồn: xoá bí mật TRƯỚC (lỗi -> giữ nguồn để thử lại), rồi xoá dòng DB.
    public func delete(id: UUID) throws {
        let ref = MetricsSource.secretReference(for: id)
        if let credentials {
            if credentials.exists(ref: ref) { try credentials.delete(ref: ref) }
        }
        try repository.delete(id: id)
    }

    // MARK: - "Xoá mọi mật khẩu đã lưu" (ADR-021)

    /// Số nguồn đang có bí mật trong kho.
    public func savedSecretCount() -> Int {
        guard let credentials, let sources = try? repository.all() else { return 0 }
        return sources.filter { s in s.credentialRef.map { credentials.exists(ref: $0) } ?? false }.count
    }

    /// Xoá bí mật của mọi nguồn (giữ nguồn). Trả (đã xoá, lỗi).
    public func purgeSecrets() -> (removed: Int, failed: Int) {
        guard let credentials, let sources = try? repository.all() else { return (0, 0) }
        var removed = 0
        var failed = 0
        for s in sources {
            let ref = MetricsSource.secretReference(for: s.id)
            let had = credentials.exists(ref: ref)
            do {
                try credentials.delete(ref: ref)
                if had { removed += 1 }
            } catch { failed += 1 }
        }
        return (removed, failed)
    }
}
