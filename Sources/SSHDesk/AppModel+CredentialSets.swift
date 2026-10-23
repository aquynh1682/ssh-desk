import Foundation
import SSHDeskCore

/// Đích của sheet "Gán bộ đăng nhập…" cho cả thư mục.
struct AssignSetTarget: Identifiable {
    let folder: String
    var id: String { folder }
}

extension AppModel {
    static func setMessage(_ error: Error) -> String {
        switch error {
        case CredentialSetError.invalidName: return "Tên bộ phải dài 1–100 ký tự và không chứa ký tự điều khiển."
        case CredentialSetError.duplicateName(let n): return "Đã có bộ tên “\(n)” (không phân biệt hoa thường)."
        case CredentialSetError.notFound: return "Không tìm thấy bộ đăng nhập (có thể đã bị xoá)."
        case CredentialSetError.invalidUser(let u): return "User “\(u)” không hợp lệ."
        case CredentialSetError.invalidIdentityFile:
            return "Đường dẫn key phải tuyệt đối, không chứa '%' hay ký tự điều khiển."
        case CredentialSetError.invalidIdentityAgent:
            return
                "Đường dẫn agent phải bắt đầu bằng '/' hoặc '~/' (hoặc SSH_AUTH_SOCK), không chứa '%', '$' hay ký tự điều khiển."
        case CredentialSetError.invalidField(let f): return "Trường \(f) không hợp lệ."
        default: return message(for: error)
        }
    }

    /// Lưu bộ (tạo mới hoặc sửa) + password/passphrase tuỳ chọn (rỗng = giữ nguyên). Trả true nếu thành công.
    func saveCredentialSet(
        _ set: CredentialSet, isNew: Bool, password: String?, passphrase: String?
    ) async -> Bool {
        guard let service else { return false }
        do {
            var saved = set
            if isNew {
                saved = try await service.createCredentialSet(
                    set, password: password, passphrase: passphrase)
            } else {
                saved = try await service.updateCredentialSet(set)
                if let password, !password.isEmpty {
                    try await service.saveSetPassword(setID: saved.id, password: password)
                }
                if let passphrase, !passphrase.isEmpty {
                    try await service.saveSetPassphrase(setID: saved.id, passphrase: passphrase)
                }
            }
            await reload()
            return true
        } catch {
            alert = AppAlert(title: "Không lưu được bộ đăng nhập", message: Self.setMessage(error))
            return false
        }
    }

    func clearSetSecret(_ setID: UUID, passphrase: Bool) async {
        guard let service else { return }
        do {
            if passphrase {
                try await service.clearSetPassphrase(setID: setID)
            } else {
                try await service.clearSetPassword(setID: setID)
            }
            await reload()
            showToast(passphrase ? "Đã xoá passphrase của bộ" : "Đã xoá mật khẩu của bộ")
        } catch { show(error, title: "Không xoá được") }
    }

    func deleteCredentialSet(_ id: UUID) async {
        guard let service else { return }
        do {
            let n = try await service.deleteCredentialSet(id: id).count
            await reload()
            showToast(n > 0 ? "Đã xoá bộ; \(n) máy chủ không còn dùng bộ" : "Đã xoá bộ đăng nhập")
        } catch ConnectionServiceError.setDeletedButKeychainFailed(let n) {
            await reload()
            alert = AppAlert(
                title: "Đã xoá bộ nhưng chưa dọn hết Keychain",
                message:
                    "Bộ đã bị xoá; \(n) mục mật khẩu/passphrase trong Keychain không xoá được (Keychain từ chối). Có thể xoá tay trong Keychain Access (service local.sshdesk.credentials)."
            )
        } catch { alert = AppAlert(title: "Không xoá được bộ", message: Self.setMessage(error)) }
    }

    /// Gán (hoặc gỡ, `setID == nil`) bộ cho các máy trong danh sách. Gán bằng tay: không hold.
    func assignCredentialSet(_ setID: UUID?, to hostIDs: [UUID]) async {
        guard let service else { return }
        do {
            let n = try await service.assignCredentialSet(setID: setID, to: hostIDs)
            await reload()
            showToast(setID == nil ? "Đã gỡ bộ khỏi \(n) máy" : "Đã gán bộ cho \(n) máy")
        } catch { alert = AppAlert(title: "Không gán được bộ", message: Self.setMessage(error)) }
    }

    func confirmAutofillHold(_ host: HostProfile) async {
        guard let service else { return }
        do {
            try await service.confirmAutofillHold(hostID: host.id)
            await reload()
            showToast("Đã xác nhận — tự điền mật khẩu hoạt động lại")
        } catch { show(error, title: "Không xác nhận được") }
    }

    /// Máy trong thư mục (đúng nghĩa "thuộc thư mục này") có thể nhận bộ: SSH managed hoặc Windows.
    func assignableHosts(inFolder folder: String) -> [HostProfile] {
        hosts.filter { $0.project == folder && ($0.kind == .windowsRDP || $0.connectionMode == .managed) }
    }

    /// File key hiệu lực (của máy hoặc bộ) không tồn tại → đường dẫn. Chỉ fileExists.
    func missingKeyPath(for host: HostProfile) -> String? {
        guard host.kind == .ssh, host.connectionMode == .managed else { return nil }
        let r = CredentialResolution.resolve(
            host: host, set: credentialSet(id: host.credentialSetID), settingsDefaultAgent: nil)
        guard let file = r.identityFile else { return nil }
        let path = CredentialResolution.expandTilde(file, home: NSHomeDirectory())
        return FileManager.default.fileExists(atPath: path) ? nil : file
    }

    func passwordSource(for host: HostProfile) -> PasswordSource {
        CredentialResolution.passwordSource(host: host, set: credentialSet(id: host.credentialSetID))
    }
}
