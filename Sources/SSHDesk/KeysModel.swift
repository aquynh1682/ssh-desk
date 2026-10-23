import AppKit
import Foundation
import Observation
import SSHDeskCore

/// Việc đang chạy của màn SSH Keys (tạo key hoặc cài key). Một lúc chỉ một việc.
struct KeyTaskInfo: Equatable {
    enum Kind: Equatable {
        case generate(name: String)
        case install(keyName: String, hostName: String)
    }
    let kind: Kind

    var title: String {
        switch kind {
        case .generate(let n): return "Đang tạo key “\(n)”…"
        case .install(let k, let h): return "Đang cài key “\(k)” lên “\(h)”…"
        }
    }

    /// Dòng nguồn trên thẻ prompt.
    var context: String {
        switch kind {
        case .generate(let n): return "\(n) · Tạo key"
        case .install(let k, let h): return "\(h) · Cài key \(k)"
        }
    }
}

/// Đề nghị đổi host sang xác thực bằng key vừa cài.
struct KeyAdoptionOffer: Identifiable {
    let id = UUID()
    let host: HostProfile
    let key: SSHKeyInfo
}

@MainActor @Observable
final class KeysModel {
    unowned let app: AppModel
    private let inventory: SSHKeyInventory
    private let secureEnclave: SecureEnclaveKeyService

    var keys: [SSHKeyInfo] = []
    var loaded = false
    var selectionName: String?
    var task: KeyTaskInfo?
    var pendingPrompt: PromptKind?
    /// Form tạo key.
    var showGenerate = false
    /// Menu ⋯ của host: chọn key để cài lên host này.
    var pickKeyForHost: HostProfile?
    /// PROD: chờ xác nhận trước khi cài.
    var confirmProdInstall: (key: SSHKeyInfo, host: HostProfile)?
    var adoptionOffer: KeyAdoptionOffer?

    /// Agent đang xem ở mục "Key trong agent": nil = mặc định trong Cài đặt (hoặc hệ thống).
    var agentPreset: IdentityAgentPreset?
    var agentListing: AgentKeyListing?
    var agentLoading = false

    /// Khoá Secure Enclave (ADR-027). Mục bị ẩn khi máy thiếu dylib/sc_auth.
    var seIdentities: [SecureEnclaveIdentity] = []
    var seBusy = false
    var showCreateSE = false
    var pendingDeleteSE: SecureEnclaveIdentity?
    /// Tạo identity xong nhưng xuất file handle lỗi: đề nghị xoá (không tự xoá im lặng).
    var seFailedLabel: (label: String, reason: String)?

    private var session: KeyTaskSession?

    init(app: AppModel, directory: URL = SSHKeyInventory.defaultDirectory) {
        self.app = app
        inventory = SSHKeyInventory(directory: directory)
        secureEnclave = SecureEnclaveKeyService(
            directory: directory, helper: ControllingTTYHelper.defaultURL())
    }

    var seAvailable: Bool { secureEnclave.isAvailable }

    var selected: SSHKeyInfo? { keys.first { $0.name == selectionName } }
    var isBusy: Bool { task != nil || seBusy }

    func refresh() async {
        keys = await inventory.list()
        await refreshSecureEnclave()
        loaded = true
        if let s = selectionName, !keys.contains(where: { $0.name == s }) { selectionName = nil }
    }

    // MARK: - Khoá Secure Enclave (ADR-027)

    func refreshSecureEnclave() async {
        guard seAvailable else {
            seIdentities = []
            return
        }
        seIdentities = (try? await secureEnclave.list()) ?? []
    }

    /// Có cặp file handle (cả hai file thường) trong thư mục khoá.
    func seHasHandle(_ identity: SecureEnclaveIdentity) -> Bool {
        secureEnclave.hasHandleFiles(label: identity.label)
    }

    /// Cặp key E1 tương ứng với handle (để cài lên server / đổi xác thực host).
    func seKeyInfo(_ identity: SecureEnclaveIdentity) -> SSHKeyInfo? {
        let name = SecureEnclaveKeyService.handleName(label: identity.label)
        return keys.first { $0.name == name && !$0.isSymlink }
    }

    var seErrorLabels: Set<String> { Set(seIdentities.map(\.label)) }

    /// true nếu đã tạo xong (form đóng).
    func createSecureEnclave(label: String, protection: SecureEnclaveProtection) async -> Bool {
        guard !isBusy else { return false }
        seBusy = true
        defer { seBusy = false }
        do {
            try await secureEnclave.create(label: label, protection: protection)
            await refresh()
            selectionName = SecureEnclaveKeyService.handleName(label: label)
            app.showToast("Đã tạo khoá Secure Enclave “\(label)”")
            return true
        } catch SecureEnclaveError.handleExportFailed(let label, let reason) {
            await refresh()
            seFailedLabel = (label, reason)
            return true
        } catch {
            app.show(error, title: "Không tạo được khoá Secure Enclave")
            return false
        }
    }

    func deleteSecureEnclave(label: String) async {
        guard !isBusy else { return }
        seBusy = true
        defer { seBusy = false }
        do {
            try await secureEnclave.delete(label: label)
            app.showToast("Đã xoá khoá Secure Enclave “\(label)”")
        } catch {
            app.show(error, title: "Không xoá được khoá Secure Enclave")
        }
        await refresh()
    }

    // MARK: - Key trong agent (ADR-024)

    /// Giá trị agent đang xem (đường dẫn/`SSH_AUTH_SOCK`); nil = agent hệ thống.
    var agentValue: String? {
        IdentityAgentResolution.effective(
            host: agentPreset?.path, settingsDefault: app.settings.defaultIdentityAgent)
    }

    /// Chạy `ssh-add -L` (chỉ đọc public key). Không thêm/xoá key.
    func refreshAgent() async {
        agentLoading = true
        let value = agentValue
        agentListing = await AgentKeyLister.list(agent: value)
        agentLoading = false
    }

    // MARK: - Public key / Finder

    /// Copy nội dung file `.pub` (public, không bí mật). Không bao giờ đụng private key.
    func copyPublicKey(_ key: SSHKeyInfo) {
        guard let text = inventory.publicKeyText(key) else {
            app.alert = AppAlert(title: "Không đọc được public key", message: key.publicKeyPath)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.showToast("Đã copy public key “\(key.name)”")
    }

    func revealInFinder(_ key: SSHKeyInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: key.publicKeyPath)])
    }

    // MARK: - Tạo key

    /// Trả true nếu tác vụ đã bắt đầu (form đóng). Lỗi validate/đã tồn tại → alert.
    func generate(name: String, comment: String) async -> Bool {
        guard !isBusy else { return false }
        do {
            let generator = try SSHKeyGenerator(
                directory: inventory.directory, name: name, comment: comment,
                helper: ControllingTTYHelper.defaultURL())
            let session = try await generator.start()
            run(session, info: KeyTaskInfo(kind: .generate(name: name))) { [weak self] outcome in
                guard let self else { return }
                await self.refresh()
                if case .success = outcome { self.selectionName = name }
            }
            return true
        } catch {
            app.show(error, title: "Không tạo được key")
            return false
        }
    }

    // MARK: - Cài key

    /// PROD cần xác nhận; còn lại cài ngay.
    func requestInstall(key: SSHKeyInfo, host: HostProfile) {
        guard !isBusy else {
            app.showToast("Đang có một tác vụ khoá khác chạy")
            return
        }
        if host.environment == .prod {
            confirmProdInstall = (key, host)
        } else {
            Task { await install(key: key, host: host) }
        }
    }

    func install(key: SSHKeyInfo, host: HostProfile) async {
        guard !isBusy, let service = app.service else { return }
        do {
            guard let alias = host.sshAlias else { throw ConnectionServiceError.missingAlias }
            // Config có thể cũ so với hồ sơ: sinh lại trước khi ssh-copy-id đọc.
            try await service.regenerateSSHConfig()
            // Host đã cấu hình key khác: bước lọc của ssh-copy-id sẽ nhầm (đăng nhập được bằng key cũ).
            let force = host.connectionMode == .managed && host.authMethod == .keyFile
            let installer = try SSHKeyInstaller(
                configPath: app.paths.sshConfigURL.path, publicKeyPath: key.publicKeyPath, alias: alias,
                host: host, credentials: app.autofillCredentials, helper: ControllingTTYHelper.defaultURL(),
                force: force)
            let session = try await installer.start()
            run(session, info: KeyTaskInfo(kind: .install(keyName: key.name, hostName: host.displayName))) {
                [weak self] outcome in
                guard let self, case .success = outcome else { return }
                self.offerAdoption(host: host, key: key)
            }
        } catch {
            app.show(error, title: "Không cài được key")
        }
    }

    private func offerAdoption(host: HostProfile, key: SSHKeyInfo) {
        guard key.hasPrivateKey else { return }
        if host.connectionMode == .managed {
            adoptionOffer = KeyAdoptionOffer(host: host, key: key)
        } else {
            app.showToast(
                "Máy chủ import từ SSH config: app không sửa, hãy tự thêm IdentityFile cho “\(host.displayName)”.")
        }
    }

    func confirmAdoption(_ offer: KeyAdoptionOffer) async {
        adoptionOffer = nil
        guard let service = app.service, let path = offer.key.privateKeyPath else { return }
        do {
            try await service.useKey(hostID: offer.host.id, privateKeyPath: path)
            await app.reload()
            app.showToast("Đã đổi “\(offer.host.displayName)” sang xác thực bằng key “\(offer.key.name)”")
        } catch {
            app.show(error, title: "Không đổi được cách xác thực")
        }
    }

    // MARK: - Phiên tác vụ

    func respond(text: String, isSecret: Bool) {
        pendingPrompt = nil
        guard let session else { return }
        Task { await session.respond(text: text, isSecret: isSecret) }
    }

    func cancelTask() {
        pendingPrompt = nil
        guard let session else { return }
        Task { await session.cancel() }
    }

    private func run(
        _ session: KeyTaskSession, info: KeyTaskInfo,
        onFinish: @escaping @MainActor (KeyTaskOutcome) async -> Void
    ) {
        self.session = session
        task = info
        pendingPrompt = nil
        Task { [weak self] in
            var result: KeyTaskOutcome = .cancelled
            for await event in session.events {
                switch event {
                case .authPrompt(let kind): self?.pendingPrompt = kind
                case .finished(let outcome): result = outcome
                }
            }
            guard let self else { return }
            self.session = nil
            self.task = nil
            self.pendingPrompt = nil
            switch result {
            case .success(let message): self.app.showToast(message)
            case .failure(let reason):
                self.app.alert = AppAlert(title: "Tác vụ khoá thất bại", message: reason)
            case .cancelled: self.app.showToast("Đã huỷ tác vụ")
            }
            await onFinish(result)
        }
    }

    /// Thoát app: dừng tác vụ đang chạy.
    func shutdown() async {
        await session?.cancel()
    }
}
