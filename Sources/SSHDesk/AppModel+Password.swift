import Foundation
import SSHDeskCore

// ADR-029: hỏi mật khẩu lần đầu. Quyết định ở Core (`MissingPasswordPrompt.decide`); ở đây chỉ nối vào UI.

extension AppModel {
    /// Hỏi mật khẩu nếu máy cần (đúng điều kiện ADR-029). `notNeeded` = đi tiếp luồng cũ.
    /// - `owner`: chủ của mật khẩu tạm khi người dùng không tích lưu (xem `EphemeralPasswordVault`); người gọi
    ///   chịu trách nhiệm `release` khi phiên/job kết thúc. Với Warp/Windows không dùng vault.
    func requestMissingPassword(
        for host: HostProfile, purpose: PasswordPurpose, presenter: PasswordPresenter = .root,
        owner: String?
    ) async -> PasswordAnswer {
        guard let repo = hostRepository else { return .notNeeded }
        let fresh = (try? await repo.host(id: host.id)) ?? host
        // Phiên khác đã nhập mật khẩu tạm cho máy này (vd Monitor chạy lại): không hỏi lại.
        if purpose == .session, ephemeralVault.has(hostID: fresh.id) {
            if let owner { ephemeralVault.share(hostID: fresh.id, owner: owner) }
            return .notNeeded
        }
        let resolved = try? await repo.resolvedCredentials(
            for: fresh,
            settingsDefaultAgent: settings.defaultIdentityAgent.isEmpty ? nil : settings.defaultIdentityAgent)
        let decision = MissingPasswordPrompt.decide(
            host: fresh, resolved: resolved, settings: settings, store: credentials)
        guard decision != .none else { return .notNeeded }
        let request = PasswordPromptRequest(
            host: fresh, decision: decision, purpose: purpose, presenter: presenter)
        let answer = await passwordPrompts.ask(request)
        if case .saved = answer { await reload() }
        return answer
    }

    // MARK: - Gửi từ sheet

    func submitPasswordPrompt(
        _ request: PasswordPromptRequest, password: String, save: Bool, choice: PasswordSaveChoice
    ) async {
        let host = request.host
        if request.decision == .windows {
            guard save else {
                passwordPrompts.complete(request, .windowsCopy(password))
                return
            }
            // Máy Windows: không kiểm tra được (ADR-029), lưu thẳng rồi để luồng mở copy từ kho.
            request.phase = .verifying
            do {
                _ = try await service?.savePassword(hostID: host.id, password: password)
                passwordPrompts.complete(request, .saved)
            } catch {
                request.phase = .failed("Không lưu được mật khẩu: \(Self.message(for: error))")
            }
            return
        }
        guard save else {
            passwordPrompts.complete(
                request, request.purpose == .warp ? .skipToTerminal : .sessionOnly(password))
            return
        }
        guard let entry = passwordEntry else {
            request.phase = .failed("Dữ liệu chưa sẵn sàng.")
            return
        }
        request.phase = .verifying
        let result = await entry.save(hostID: host.id, password: password, choice: choice)
        apply(result, to: request)
    }

    func saveAnywayFromPrompt(
        _ request: PasswordPromptRequest, password: String, choice: PasswordSaveChoice
    ) async {
        guard let entry = passwordEntry else { return }
        let result = await entry.saveWithoutVerifying(
            hostID: request.host.id, password: password, choice: choice)
        apply(result, to: request)
    }

    func updateSetPasswordFromPrompt(_ request: PasswordPromptRequest, setID: UUID, newPassword: String) async {
        guard let entry = passwordEntry else { return }
        let result = await entry.updateSetPassword(
            hostID: request.host.id, setID: setID, newPassword: newPassword)
        apply(result, to: request)
    }

    private func apply(_ result: PasswordEntryResult, to request: PasswordPromptRequest) {
        switch result {
        case .saved:
            passwordPrompts.complete(request, .saved)
        case .wrongPassword:
            request.phase = .failed("Sai mật khẩu. Hãy nhập lại.")
        case .setPasswordWrong(let setID, let name, let affected):
            request.phase = .setWrong(setName: name, affected: affected, setID: setID)
        case .blocked(let why):
            request.phase = .failed(Self.blockedText(why, purpose: request.purpose))
        case .unverifiable(let why):
            request.phase = .confirmUnverified(Self.unverifiableText(why))
        case .invalid(let message), .failed(let message):
            request.phase = .failed(message)
        }
    }

    static func blockedText(_ why: PasswordVerification, purpose: PasswordPurpose) -> String {
        let terminal = purpose == .warp ? " (Bỏ qua, nhập trong terminal)" : ""
        switch why {
        case .hostKeyUnconfirmed:
            return
                "Chưa xác nhận host key — hãy mở terminal lần đầu\(terminal) để xác nhận khoá của máy, rồi thử lại."
        case .hostKeyChanged:
            return "Host key của máy đã thay đổi — dừng lại và kiểm tra known_hosts trước khi kết nối."
        case .otherPrompt:
            return
                "Máy yêu cầu thêm bước xác thực (OTP/MFA/passphrase) hoặc hỏi theo cách khác — không kiểm tra được. Hãy đăng nhập trong terminal\(terminal)."
        default:
            return "Không kiểm tra được."
        }
    }

    static func unverifiableText(_ why: PasswordVerification) -> String {
        switch why {
        case .timeout: return "Hết thời gian chờ (20 giây) khi kiểm tra đăng nhập."
        case .networkError(let m): return "Lỗi kết nối: \(m)"
        default: return "Không kiểm tra được đăng nhập."
        }
    }

    // MARK: - Mật khẩu tạm cho phiên

    /// Gói "hỏi → (không tích lưu) giữ trong bộ nhớ cho `owner`". Trả false nếu người dùng huỷ.
    func preparePasswordForSession(
        _ host: HostProfile, owner: String, presenter: PasswordPresenter = .root
    ) async -> Bool {
        let answer = await requestMissingPassword(
            for: host, purpose: .session, presenter: presenter, owner: owner)
        switch answer {
        case .cancelled: return false
        case .sessionOnly(let password):
            ephemeralVault.retain(host: host, password: password, owner: owner)
            return true
        default: return true
        }
    }
}

extension AppModel {
    /// Hỏi tuần tự (mỗi lúc một sheet, ADR-019) cho mọi máy SSH chưa có mật khẩu. Huỷ = bỏ qua máy đó.
    /// Mật khẩu không tích lưu được giữ trong vault cho `owner` (người gọi `releaseAll(owner:)` khi xong).
    func preparePasswords(for hosts: [HostProfile], owner: String) async
        -> (run: [HostProfile], skipped: [HostProfile])
    {
        var run: [HostProfile] = []
        var skipped: [HostProfile] = []
        for host in hosts {
            if host.kind == .ssh, await preparePasswordForSession(host, owner: owner) == false {
                skipped.append(host)
            } else {
                run.append(host)
            }
        }
        return (run, skipped)
    }
}
