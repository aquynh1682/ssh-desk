import Observation
import SSHDeskCore
import SwiftUI

// ADR-029: sheet "Nhập mật khẩu cho user@host". Logic quyết định/kiểm tra/lưu nằm ở SSHDeskCore
// (`MissingPasswordPrompt`, `PasswordVerifier`, `PasswordEntryService`); file này chỉ là hàng đợi + giao diện.

/// Luồng nào đang xin mật khẩu (đổi nút/lời nhắc của sheet).
enum PasswordPurpose {
    /// Mở Warp: có nút "Bỏ qua, nhập trong terminal".
    case warp
    /// Analyst / Monitor / Truyền file / Duyệt file / Tunnel: không tích lưu thì chỉ giữ trong bộ nhớ của phiên.
    case session
    /// Máy Windows (ADR-018).
    case windows
}

/// View nào được phép hiện sheet này (SwiftUI không hiện hai sheet cùng lúc trên một view; sheet Tải về/Tải lên
/// hiện sheet mật khẩu lồng bên trong chính nó).
enum PasswordPresenter {
    case root
    case transferSheet
}

enum PasswordAnswer {
    /// Không cần hỏi (đã có mật khẩu, cài đặt tắt...).
    case notNeeded
    /// Đã kiểm tra và lưu; hồ sơ máy đã cập nhật.
    case saved
    /// Không tích lưu: mật khẩu chỉ dành cho phiên/job này (người gọi đặt vào `EphemeralPasswordVault`).
    case sessionOnly(String)
    /// Windows, không tích lưu: copy một lần.
    case windowsCopy(String)
    /// Warp: người dùng tự nhập trong terminal.
    case skipToTerminal
    case cancelled
}

@MainActor @Observable
final class PasswordPromptRequest: Identifiable {
    enum Phase: Equatable {
        case editing
        case verifying
        case failed(String)
        /// Mật khẩu của bộ không đúng với máy này (không ghi đè bộ).
        case setWrong(setName: String, affected: Int, setID: UUID)
        /// Lỗi mạng/timeout: "Không kiểm tra được. Vẫn lưu?"
        case confirmUnverified(String)
    }

    let id = UUID()
    let host: HostProfile
    let decision: MissingPasswordPrompt.Decision
    let purpose: PasswordPurpose
    let presenter: PasswordPresenter
    var phase = Phase.editing
    @ObservationIgnored fileprivate var continuation: CheckedContinuation<PasswordAnswer, Never>?

    init(
        host: HostProfile, decision: MissingPasswordPrompt.Decision, purpose: PasswordPurpose,
        presenter: PasswordPresenter
    ) {
        self.host = host
        self.decision = decision
        self.purpose = purpose
        self.presenter = presenter
    }

    fileprivate func resume(_ answer: PasswordAnswer) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

/// Hàng đợi sheet: mỗi lúc chỉ một sheet (Monitor hỏi tuần tự, ADR-019).
@MainActor @Observable
final class PasswordPromptCenter {
    private(set) var current: PasswordPromptRequest?
    @ObservationIgnored private var waiting: [PasswordPromptRequest] = []

    func ask(_ request: PasswordPromptRequest) async -> PasswordAnswer {
        await withCheckedContinuation { continuation in
            request.continuation = continuation
            waiting.append(request)
            pump()
        }
    }

    func complete(_ request: PasswordPromptRequest, _ answer: PasswordAnswer) {
        request.resume(answer)
        if current?.id == request.id {
            current = nil
            // Chờ sheet cũ đóng hẳn rồi mới hiện sheet kế tiếp.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.pump()
            }
        }
    }

    func current(for presenter: PasswordPresenter) -> PasswordPromptRequest? {
        guard let current, current.presenter == presenter else { return nil }
        return current
    }

    /// Đóng bằng Esc/vuốt xuống = Huỷ.
    func dismissCurrent(for presenter: PasswordPresenter) {
        if let request = current(for: presenter) { complete(request, .cancelled) }
    }

    private func pump() {
        guard current == nil, !waiting.isEmpty else { return }
        current = waiting.removeFirst()
    }
}

extension View {
    /// Gắn sheet mật khẩu cho một presenter.
    func passwordPromptSheet(model: AppModel, presenter: PasswordPresenter) -> some View {
        sheet(
            item: Binding<PasswordPromptRequest?>(
                get: { model.passwordPrompts.current(for: presenter) },
                set: { if $0 == nil { model.passwordPrompts.dismissCurrent(for: presenter) } })
        ) { request in
            PasswordPromptSheet(model: model, request: request)
        }
    }
}

// MARK: - Sheet

private enum SaveKind: Hashable {
    case thisHost, existingSet, newSet
}

struct PasswordPromptSheet: View {
    let model: AppModel
    @Bindable var request: PasswordPromptRequest
    @Local private var password = ""
    @Local private var save = true
    @Local private var kind = SaveKind.thisHost
    @Local private var setID: UUID?
    @Local private var newSetName = ""
    @Local private var updatedSetPassword = ""
    @Local private var seeded = false

    private var isWindows: Bool { request.decision == .windows }
    private var isWarp: Bool { request.purpose == .warp }
    private var usableSets: [CredentialSet] { model.credentialSets.filter { model.setHasPassword($0.id) } }
    private var identity: String {
        isWindows
            ? (request.host.rdpUsername.isEmpty ? request.host.displayName : request.host.rdpUsername)
                + "@" + request.host.hostName
            : request.host.user + "@" + request.host.hostName
    }
    private var busy: Bool { request.phase == .verifying }
    /// Với bộ có sẵn thì không nhập lại: kiểm bằng password của bộ.
    private var needsPasswordField: Bool {
        guard !(isWarp && !save) else { return false }
        return !(save && kind == .existingSet && !isWindows)
    }
    private var canSubmit: Bool {
        if busy { return false }
        if needsPasswordField && password.isEmpty { return false }
        if save && !isWindows {
            if kind == .existingSet && setID == nil { return false }
            if kind == .newSet && newSetName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(Theme.textSecondary)
                Text("Nhập mật khẩu cho \(identity)").font(.title3.bold())
            }
            HStack(spacing: 8) {
                Text(request.host.displayName).font(.headline)
                EnvironmentBadge(environment: request.host.environment)
            }
            switch request.phase {
            case .setWrong(let name, let affected, let id):
                setWrongSection(name: name, affected: affected, setID: id)
            case .confirmUnverified(let why):
                unverifiedSection(why)
            default:
                form
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460)
        .frame(minHeight: 280)
        .interactiveDismissDisabled(busy)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            let base = request.host.project.isEmpty ? request.host.displayName : request.host.project
            newSetName = "Bộ " + base
            setID = usableSets.first?.id
            if isWarp { save = true }
        }
    }

    // MARK: Form

    @ViewBuilder private var form: some View {
        if needsPasswordField {
            SecureField("Mật khẩu", text: $password)
                .textFieldStyle(.roundedBorder).disabled(busy)
                .onSubmit { submit() }
        }
        Toggle("Lưu vào Keychain", isOn: $save).disabled(busy)
        if save && !isWindows { destinations }
        explanation
        if case .failed(let message) = request.phase {
            Text(message).font(.callout).foregroundStyle(Theme.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Đang kiểm tra đăng nhập…").font(.callout).foregroundStyle(Theme.textSecondary)
            }
        }
        HStack {
            if isWarp {
                Button("Bỏ qua, nhập trong terminal") { finish(.skipToTerminal) }.disabled(busy)
            }
            Spacer()
            Button("Huỷ") { finish(.cancelled) }.keyboardShortcut(.cancelAction).disabled(busy)
            Button(isWarp && !save ? "Mở Warp" : "Tiếp tục") { submit() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canSubmit)
        }
    }

    @ViewBuilder private var destinations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $kind) {
                Text("Chỉ lưu cho máy này").tag(SaveKind.thisHost)
                Text("Dùng bộ đăng nhập có sẵn").tag(SaveKind.existingSet)
                Text("Lưu thành bộ mới").tag(SaveKind.newSet)
            }
            .pickerStyle(.radioGroup).labelsHidden().disabled(busy)
            if kind == .existingSet {
                if usableSets.isEmpty {
                    Text("Chưa có bộ nào đã đặt mật khẩu.").font(.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Picker("Bộ", selection: $setID) {
                        ForEach(usableSets) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .disabled(busy)
                    Text("Kiểm tra bằng mật khẩu của bộ, không cần nhập lại.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if kind == .newSet {
                TextField("Tên bộ", text: $newSetName).textFieldStyle(.roundedBorder).disabled(busy)
            }
        }
        .padding(.leading, 4)
    }

    private var explanation: some View {
        let text: String
        if isWindows {
            text =
                save
                ? "Lưu mật khẩu (không kiểm tra được), rồi copy vào clipboard để dán (⌘V) vào Windows App."
                : "Không lưu: copy một lần vào clipboard, tự xoá sau \(model.settings.clipboardClearSeconds) giây."
        } else if !save {
            text =
                isWarp
                ? "Không lưu: mở Warp và nhập mật khẩu ngay trong terminal; app không giữ mật khẩu."
                : "Không lưu: mật khẩu chỉ nằm trong bộ nhớ cho phiên này và bỏ khi phiên đóng."
        } else {
            text = "Kiểm tra đăng nhập trước khi lưu. Mật khẩu chỉ nằm trong Keychain, không bao giờ vào file hay log."
        }
        return Text(text).font(.caption).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Phase đặc biệt

    @ViewBuilder private func setWrongSection(name: String, affected: Int, setID id: UUID) -> some View {
        Text("Mật khẩu của bộ “\(name)” không đúng với máy này.")
            .font(.callout).foregroundStyle(Theme.red)
        Text("Bộ không bị thay đổi. Nếu mật khẩu mới là đúng, bạn có thể cập nhật mật khẩu của bộ.")
            .font(.caption).foregroundStyle(Theme.textSecondary)
        SecureField("Mật khẩu mới của bộ", text: $updatedSetPassword).textFieldStyle(.roundedBorder)
        HStack {
            Button("Quay lại") {
                updatedSetPassword = ""
                request.phase = .editing
            }
            Spacer()
            Button("Cập nhật mật khẩu của bộ (ảnh hưởng \(affected) máy)", role: .destructive) {
                let pw = updatedSetPassword
                updatedSetPassword = ""
                request.phase = .verifying
                Task { await model.updateSetPasswordFromPrompt(request, setID: id, newPassword: pw) }
            }
            .disabled(updatedSetPassword.isEmpty)
        }
    }

    @ViewBuilder private func unverifiedSection(_ why: String) -> some View {
        Text(why).font(.callout).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
        Text("Không kiểm tra được. Vẫn lưu?").font(.headline)
        HStack {
            Spacer()
            Button("Vẫn lưu") {
                request.phase = .verifying
                Task { await model.saveAnywayFromPrompt(request, password: password, choice: choice) }
            }
            Button("Không") {
                request.phase = .editing
            }
            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
    }

    // MARK: Hành động

    private var choice: PasswordSaveChoice {
        switch kind {
        case .thisHost: return .thisHostOnly
        case .existingSet: return setID.map(PasswordSaveChoice.existingSet) ?? .thisHostOnly
        case .newSet: return .newSet(name: newSetName)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let pw = password
        let selected = choice
        let saving = save
        Task {
            await model.submitPasswordPrompt(request, password: pw, save: saving, choice: selected)
            // Sai/ lỗi: xoá ô nhập để gõ lại; thành công thì sheet đóng.
            if case .failed = request.phase { password = "" }
        }
    }

    private func finish(_ answer: PasswordAnswer) {
        password = ""
        model.passwordPrompts.complete(request, answer)
    }
}
