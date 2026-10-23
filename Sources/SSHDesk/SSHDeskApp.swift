import AppKit
import SSHDeskCore
import SwiftUI

/// Đảm bảo app chạy như ứng dụng thường (Dock, focus) cả khi chạy từ `swift run`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Nhận `sshdesk://` bằng Apple Event (chạy được cả khi app đang tắt: URL tới khi khởi động). ADR-025.
    func applicationWillFinishLaunching(_ notification: Notification) {
        registerURLHandler()
    }

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: text)
        else { return }
        AppModel.shared.receive(url: url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Đăng ký lại sau khi SwiftUI dựng xong để chắc handler của ta là handler cuối.
        registerURLHandler()
        NSApplication.shared.setActivationPolicy(.regular)
        // Chạy bằng `swift run` thì không có AppIcon.icns; đặt icon Dock từ logo đóng gói trong resource.
        if Bundle.main.bundleURL.pathExtension != "app", let logo = AppLogo.image {
            NSApplication.shared.applicationIconImage = logo
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// App được kích hoạt lại: kiểm tra file nguồn có đổi không (ADR-026). Không tự áp dụng.
    func applicationDidBecomeActive(_ notification: Notification) {
        let model = AppModel.shared
        guard model.isReady else { return }
        Task { await model.inventory.checkChanges() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.secretClipboard.clearNowIfOwned()
    }

    /// Chính sách đóng cửa sổ (ADR-021): "Thoát app" -> đóng cửa sổ cuối đi qua đường thoát có xác nhận;
    /// "Giữ chạy nền" -> app sống tiếp, mở lại cửa sổ bằng Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        WindowCloseDecision.quitsOnLastWindowClose(AppModel.shared.settings)
    }

    /// Bấm Dock khi không còn cửa sổ: để SwiftUI dựng lại cửa sổ chính (job nền vẫn chạy).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    /// Thoát (⌘Q hoặc đóng cửa sổ cuối khi chính sách là Thoát), ADR-022:
    /// còn job truyền/tunnel/Monitor/Analyst/tác vụ Keys -> hộp xác nhận liệt kê từng loại. Đồng ý -> huỷ job
    /// (job chờ thành "Bị gián đoạn"), dừng tunnel, dừng Analyst/Monitor, đóng mọi master (`ssh -O exit`),
    /// xoá clipboard password rồi thoát. Tab duyệt file rảnh đóng im lặng.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let activity = model.quitActivity
        guard activity.needsConfirmation || model.hasOpenSessions else {
            return .terminateNow
        }
        Task { @MainActor in
            if activity.needsConfirmation {
                let alert = NSAlert()
                alert.messageText = QuitActivity.title
                alert.informativeText = activity.message
                alert.addButton(withTitle: QuitActivity.cancelButton)
                alert.addButton(withTitle: QuitActivity.confirmButton)
                if alert.runModal() == .alertFirstButtonReturn {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            model.secretClipboard.clearNowIfOwned()
            await model.shutdownTransfers(cancelRunning: true)
            await model.keys.shutdown()
            await model.closeAllSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct SSHDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Local private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("SSH Desk") {
            RootView(model: model)
                .frame(minWidth: 1020, minHeight: 600)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Tìm máy chủ") { model.searchFocusTick += 1 }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!model.isReady)
                Button("Tìm máy chủ (⌘F)") { model.searchFocusTick += 1 }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!model.isReady)
            }
            CommandGroup(replacing: .newItem) {
                Button("Thêm máy chủ…") { model.form = .new }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.isReady)
                Button("Import từ SSH config…") { model.showImport = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!model.isReady)
                Divider()
                Button("Xuất danh sách máy chủ…") { model.exportHosts(.all) }
                    .disabled(!model.isReady || model.hosts.isEmpty)
                Button("Nhập danh sách máy chủ…") { model.beginImportFile() }
                    .disabled(!model.isReady)
                Button("Nguồn máy chủ (Excel/CSV)…") { model.inventory.openHub() }
                    .disabled(!model.isReady)
            }
            // Thao tác trên máy chủ đang chọn (ADR-022). Xoá dùng ⌘⌫ (không dùng ⌫ trần để khỏi tranh phím
            // với ô nhập); trong bảng máy chủ phím ⌫ cũng hỏi xoá.
            CommandMenu("Máy chủ") {
                Button("Mở (Warp / Windows App)") { model.openSelected() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.hasSelectedHost)
                Button("Sửa…") { model.editSelected() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!model.hasSelectedHost)
                Button("Nhân bản…") { model.duplicateSelected() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!model.hasSelectedHost)
                Divider()
                Button("Xoá…") { model.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!model.hasSelectedHost)
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(AppModel.shortcutSections.enumerated()), id: \.offset) { index, entry in
                    Button(entry.title) { model.sidebar = entry.item }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .disabled(!model.isReady)
                }
            }
        }

        Settings {
            SettingsWindowContent(model: model)
        }
    }
}

/// Nội dung cửa sổ Cài đặt (⌘,). Dữ liệu chưa sẵn sàng thì chờ.
private struct SettingsWindowContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.isReady {
                SettingsView(model: model)
            } else {
                ProgressView("Đang mở dữ liệu…")
            }
        }
        .frame(width: 680, height: 620)
    }
}

extension AppModel {
    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }
}
