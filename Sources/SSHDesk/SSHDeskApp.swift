import AppKit
import SSHDeskCore
import SwiftUI

/// Đảm bảo app chạy như ứng dụng thường (Dock, focus) cả khi chạy từ `swift run`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // Chạy bằng `swift run` thì không có AppIcon.icns; đặt icon Dock từ logo đóng gói trong resource.
        if Bundle.main.bundleURL.pathExtension != "app", let logo = AppLogo.image {
            NSApplication.shared.applicationIconImage = logo
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Còn job chạy thì đóng cửa sổ KHÔNG thoát app (job tiếp tục trong lúc app còn mở; mở lại
    /// bằng Dock). Hết job thì đóng cửa sổ cuối = thoát như trước.
    /// Thứ tự thoát: hỏi về job đang chạy (hộp thoại hiện có) → huỷ job → đóng mọi master của tab
    /// duyệt file (`ssh -O exit`) → thoát. Tab không được mở lại ở lần chạy sau.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.hasActiveTransfers || model.hasOpenSessions || model.keys.isBusy else {
            return .terminateNow
        }
        Task { @MainActor in
            if model.hasActiveTransfers {
                let alert = NSAlert()
                alert.messageText = "Đang có tác vụ truyền file"
                alert.informativeText =
                    "Thoát bây giờ sẽ huỷ các tác vụ đang chạy; app không truyền tiếp sau khi thoát. Tác vụ đang chờ sẽ hiện là “Bị gián đoạn” ở lần mở sau."
                alert.addButton(withTitle: "Tiếp tục chạy")
                alert.addButton(withTitle: "Huỷ tác vụ và thoát")
                if alert.runModal() == .alertFirstButtonReturn {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                await model.shutdownTransfers(cancelRunning: true)
            }
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
            }
        }
    }
}

extension AppModel {
    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }
}
