import Foundation

public enum SessionConnectError: Error, Equatable, Sendable {
    case noAlias
    case failed(String)

    public var message: String {
        switch self {
        case .noAlias: return "hồ sơ thiếu alias SSH"
        case .failed(let m): return m
        }
    }
}

/// Mở một `RemoteSession` tới host: tự điền password đã lưu theo `PasswordAutofillPolicy`, prompt còn lại
/// chuyển cho `onPrompt` (UI). Không lưu/log nội dung người dùng nhập.
public struct SessionConnector: Sendable {
    public typealias Respond = @Sendable (String, Bool) async -> Void
    public typealias PromptHandler = @Sendable (PromptKind, @escaping Respond) -> Void

    private let configPath: String
    private let credentials: any CredentialStore
    private let helper: URL?
    private let socketDirectory: @Sendable () throws -> SocketDirectory
    private let sshPath: String

    public init(
        configPath: String, credentials: any CredentialStore, helper: URL?,
        sshPath: String = "/usr/bin/ssh",
        socketDirectory: @escaping @Sendable () throws -> SocketDirectory = { try SocketDirectory.ensure() }
    ) {
        self.configPath = configPath
        self.credentials = credentials
        self.helper = helper
        self.sshPath = sshPath
        self.socketDirectory = socketDirectory
    }

    /// Trả phiên đã `connected`. Huỷ task → đóng phiên và ném `CancellationError`.
    public func connect(host: HostProfile, onPrompt: @escaping PromptHandler) async throws
        -> RemoteSession
    {
        guard let alias = host.sshAlias else { throw SessionConnectError.noAlias }
        let dir: SocketDirectory
        do { dir = try socketDirectory() } catch {
            throw SessionConnectError.failed("không tạo được thư mục socket (\(error))")
        }
        let session = RemoteSession(
            alias: alias, configPath: configPath, hostID: host.id, socketDirectory: dir,
            sshPath: sshPath, helper: helper)
        let events = session.events
        do { try await session.start() } catch let e as RemoteSessionError {
            // Không close(): phiên chưa chạy master, close() sẽ xoá socket của master khác.
            switch e {
            case .socketInUse:
                throw SessionConnectError.failed("đã có phiên SSH khác đang dùng kết nối của máy này")
            default: throw SessionConnectError.failed("không khởi chạy được ssh (\(e))")
            }
        }
        let store = credentials
        return try await withTaskCancellationHandler {
            var filled = false
            for await event in events {
                switch event {
                case .connected:
                    return session
                case .disconnected(let reason):
                    throw SessionConnectError.failed(reason)
                case .authPrompt(let kind):
                    if PasswordAutofillPolicy.shouldAutofill(
                        prompt: kind, host: host, alreadyFilled: filled),
                        let ref = host.autofillCredentialReference
                    {
                        filled = true
                        let password = await Task.detached { store.read(ref: ref) }.value
                        if let password, !password.isEmpty {
                            await session.respond(text: password, isSecret: true)
                            continue
                        }
                    }
                    onPrompt(kind) { text, secret in
                        await session.respond(text: text, isSecret: secret)
                    }
                }
            }
            if Task.isCancelled { throw CancellationError() }
            throw SessionConnectError.failed("phiên SSH kết thúc bất ngờ")
        } onCancel: {
            Task { await session.close() }
        }
    }
}
