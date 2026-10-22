import Foundation
import Observation
import SSHDeskCore

/// Prompt xác thực đang chờ của một tunnel.
struct TunnelPendingPrompt {
    let id = UUID()
    let forwardID: UUID
    let hostID: UUID
    let kind: PromptKind
}

/// Trạng thái các tunnel `ssh -N -L` (ADR-011). Logic chạy/dừng nằm ở `TunnelManager` (Core).
@MainActor @Observable
final class TunnelsModel {
    weak var app: AppModel?
    @ObservationIgnored let manager: TunnelManager
    private(set) var statuses: [UUID: TunnelStatus] = [:]
    private(set) var pendingPrompts: [TunnelPendingPrompt] = []
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        manager = TunnelManager(
            configPath: app.paths.sshConfigURL.path, credentials: app.credentials,
            helper: ControllingTTYHelper.defaultURL())
        let events = manager.events
        eventsTask = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    var activeCount: Int { statuses.values.filter(\.isActive).count }

    func status(of id: UUID) -> TunnelStatus { statuses[id] ?? .stopped }

    func isActive(_ id: UUID) -> Bool { status(of: id).isActive }

    private func handle(_ event: TunnelEvent) {
        switch event {
        case .statusChanged(let id, _, let status):
            statuses[id] = status
            if status != .connecting { pendingPrompts.removeAll { $0.forwardID == id } }
        case .authPrompt(let id, let hostID, let kind):
            pendingPrompts.append(TunnelPendingPrompt(forwardID: id, hostID: hostID, kind: kind))
        }
    }

    // MARK: - Điều khiển

    func start(_ forward: PortForward) {
        guard let app, let host = app.hosts.first(where: { $0.id == forward.hostID }) else { return }
        Task {
            do { try await app.service?.regenerateSSHConfig() } catch {
                app.show(error, title: "Không ghi được SSH config")
                return
            }
            await manager.start(forward: forward, host: host)
        }
    }

    func stop(_ forward: PortForward) {
        Task { await manager.stop(forwardID: forward.id) }
    }

    /// Dừng mọi tunnel của host (trước khi xoá host).
    func stopTunnels(hostID: UUID) async {
        await manager.stopAll(hostID: hostID)
    }

    /// Thoát app: dừng mọi tunnel và chờ tiến trình thoát (SIGTERM process group từng phiên).
    func shutdown() async {
        pendingPrompts = []
        await manager.stopAll()
    }

    // MARK: - Prompt xác thực

    var activePrompt: ActivePrompt? {
        guard let p = pendingPrompts.first, let app,
            let forward = app.forwards.first(where: { $0.id == p.forwardID }),
            let host = app.hosts.first(where: { $0.id == p.hostID })
        else { return nil }
        return ActivePrompt(
            id: "tunnel-" + p.id.uuidString, kind: p.kind,
            context: "\(host.displayName) · tunnel \(forward.summary)",
            waiting: pendingPrompts.count - 1, cancelTitle: "Dừng tunnel",
            send: { [weak self] text, secret in self?.answer(p, text: text, secret: secret) },
            cancel: { [weak self] in self?.stop(forward) })
    }

    private func answer(_ p: TunnelPendingPrompt, text: String, secret: Bool) {
        pendingPrompts.removeAll { $0.id == p.id }
        let manager = manager
        Task { await manager.respond(forwardID: p.forwardID, text: text, isSecret: secret) }
    }
}
