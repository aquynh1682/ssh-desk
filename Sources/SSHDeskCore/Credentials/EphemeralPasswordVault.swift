import Foundation

/// Mật khẩu chỉ trong bộ nhớ, gắn với một "chủ" (phiên/job/tunnel) của một host (ADR-029, "không tích lưu").
/// Không ghi Keychain, DB, file, log. Bỏ khi chủ cuối cùng nhả (`release`). Host nhận một tham chiếu giả
/// `ephemeral-<uuid>` chỉ có nghĩa với `EphemeralOverlayCredentialStore`; `HostProfile.validate` từ chối
/// lưu tham chiếu này vào DB.
public final class EphemeralPasswordVault: @unchecked Sendable, CustomStringConvertible {
    public static let referencePrefix = "ephemeral-"

    public static func reference(for hostID: UUID) -> String {
        referencePrefix + hostID.uuidString.lowercased()
    }

    private struct Entry {
        var password: String
        var owners: Set<String>
        /// user@hostName:port lúc nhập; đổi đích thì mục tạm không còn áp dụng.
        var identity: String
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    public init() {}

    public var description: String { "EphemeralPasswordVault(count: \(lock.withLock { entries.count }))" }

    /// Giữ `password` cho `hostID` thay mặt `owner`. Gọi lại với password khác sẽ thay giá trị cho mọi chủ.
    public func retain(host: HostProfile, password: String, owner: String) {
        let hostID = host.id
        let identity = Self.identity(of: host)
        lock.withLock {
            var entry = entries[hostID] ?? Entry(password: password, owners: [], identity: identity)
            entry.password = password
            entry.identity = identity
            entry.owners.insert(owner)
            entries[hostID] = entry
        }
    }

    /// Thêm `owner` vào mục đã có của host (phiên khác dùng chung mật khẩu tạm). Không có mục thì bỏ qua.
    public func share(hostID: UUID, owner: String) {
        lock.withLock { entries[hostID]?.owners.insert(owner) }
    }

    /// Nhả phần của `owner`; hết chủ thì xoá password khỏi bộ nhớ.
    public func release(hostID: UUID, owner: String) {
        lock.withLock {
            guard var entry = entries[hostID] else { return }
            entry.owners.remove(owner)
            entries[hostID] = entry.owners.isEmpty ? nil : entry
        }
    }

    /// Nhả mọi mục của `owner` (vd Monitor dừng: nhiều host cùng một chủ).
    public func releaseAll(owner: String) {
        lock.withLock {
            for (id, var entry) in entries {
                entry.owners.remove(owner)
                entries[id] = entry.owners.isEmpty ? nil : entry
            }
        }
    }

    static func identity(of host: HostProfile) -> String {
        "\(host.user)@\(host.hostName):\(host.port)"
    }

    public func has(hostID: UUID) -> Bool { lock.withLock { entries[hostID] != nil } }

    /// Bản sao host dùng để KẾT NỐI: nếu vault có password cho host thì đặt `credentialReference` tạm
    /// (ưu tiên hơn bộ đăng nhập). Không bao giờ lưu bản sao này vào DB.
    public func adjusted(_ host: HostProfile) -> HostProfile {
        // Đổi user/hostName/port sau khi nhập: bỏ mục tạm, không bao giờ gửi password tới đích khác.
        let matches = lock.withLock { entries[host.id]?.identity == Self.identity(of: host) }
        guard matches else { return host }
        var copy = host
        copy.credentialReference = Self.reference(for: host.id)
        return copy
    }

    fileprivate func read(reference: String) -> String? {
        lock.withLock {
            guard reference.hasPrefix(Self.referencePrefix),
                let id = UUID(uuidString: String(reference.dropFirst(Self.referencePrefix.count)))
            else { return nil }
            return entries[id]?.password
        }
    }
}

/// Kho phủ: tham chiếu `ephemeral-*` đọc từ vault, mọi tham chiếu khác chuyển cho kho thật.
/// Không bao giờ ghi/xoá tham chiếu tạm ra kho thật.
public struct EphemeralOverlayCredentialStore: CredentialStore {
    private let base: any CredentialStore
    private let vault: EphemeralPasswordVault

    public init(base: any CredentialStore, vault: EphemeralPasswordVault) {
        self.base = base
        self.vault = vault
    }

    private func isEphemeral(_ ref: String) -> Bool { ref.hasPrefix(EphemeralPasswordVault.referencePrefix) }

    public func save(ref: String, password: String) throws {
        guard !isEphemeral(ref) else { throw CredentialStoreError.invalidReference }
        try base.save(ref: ref, password: password)
    }
    public func read(ref: String) -> String? {
        isEphemeral(ref) ? vault.read(reference: ref) : base.read(ref: ref)
    }
    public func delete(ref: String) throws {
        guard !isEphemeral(ref) else { return }
        try base.delete(ref: ref)
    }
    public func exists(ref: String) -> Bool {
        isEphemeral(ref) ? vault.read(reference: ref) != nil : base.exists(ref: ref)
    }
    public func status(ref: String) -> CredentialStatus {
        isEphemeral(ref) ? (vault.read(reference: ref) != nil ? .present : .missing) : base.status(ref: ref)
    }
    public func cachedStatus(ref: String) -> CredentialStatus? {
        isEphemeral(ref) ? status(ref: ref) : base.cachedStatus(ref: ref)
    }
}
