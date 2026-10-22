import AppKit
import SSHDeskCore

/// Nhận và xử lý `sshdesk://` (ADR-025). Phân tích/quy tắc xác nhận nằm trong SSHDeskCore (`OpenURLHandler`).
extension AppModel {
    /// Hàng đợi tối đa, tránh một trang web bắn hàng loạt URL để dồn hộp thoại.
    private static let maxPendingURLs = 4

    /// Gọi từ Apple Event. Chưa nạp xong dữ liệu thì xếp hàng; sẽ xử lý khi `.ready`.
    func receive(url: URL) {
        guard pendingURLs.count < Self.maxPendingURLs else { return }
        pendingURLs.append(url)
        if isReady { drainPendingURLs() }
    }

    func drainPendingURLs() {
        guard !isHandlingURLs, !pendingURLs.isEmpty else { return }
        isHandlingURLs = true
        Task { @MainActor in
            while !pendingURLs.isEmpty {
                let url = pendingURLs.removeFirst()
                await handle(url: url)
            }
            isHandlingURLs = false
        }
    }

    private func handle(url: URL) async {
        guard let service else { return }
        let intent: OpenIntent
        switch OpenURLHandler.intent(
            for: url, requestsDirectory: CLIOpenRequest.directory(in: paths))
        {
        case .failure(let failure):
            showToast("Bỏ qua liên kết sshdesk://: \(failure)")
            return
        case .success(let value): intent = value
        }
        do {
            let hosts = try await service.repository.all()
            let host = try OpenURLHandler.host(for: intent, in: hosts)
            if intent.origin.requiresConfirmation(environment: host.environment) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                let text = OpenURLHandler.confirmationText(for: host, origin: intent.origin)
                let alert = NSAlert()
                alert.alertStyle = host.environment == .prod ? .critical : .warning
                alert.messageText = text.title
                alert.informativeText = text.message
                alert.addButton(withTitle: "Huỷ")
                alert.addButton(withTitle: "Mở")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            // Cùng đường với nút "Mở Warp": ConnectionService (askpass / tự điền theo cài đặt).
            await openInWarp(host)
        } catch let e as HostResolveError {
            alert = AppAlert(title: "Không mở được máy chủ", message: e.description)
        } catch {
            show(error, title: "Không mở được máy chủ")
        }
    }
}
