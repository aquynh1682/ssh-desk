import SSHDeskCore
import SwiftUI

/// Màn "Truyền file" kiểu Xftp (ADR-013): khung Local | tab remote, hàng đợi ở đáy.
struct FileTransferView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Truyền file").font(.system(size: 26, weight: .bold))
                Text("Kéo thả file giữa Mac và các máy chủ đã kết nối")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            }
            if let browser = model.browser {
                HStack(alignment: .top, spacing: 14) {
                    LocalPaneView(browser: browser, local: browser.local)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    RemotePaneView(browser: browser, hosts: HostPresentation.sshHosts(model.hosts))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 300, maxHeight: .infinity)
                TransferQueueView(model: model).frame(height: 190)
            }
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
        .overlay {
            if let browser = model.browser { BrowserDialogHost(browser: browser) }
        }
    }
}
