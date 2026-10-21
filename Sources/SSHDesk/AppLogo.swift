import AppKit
import SwiftUI

/// Nạp logo từ resource bundle của SwiftPM mà KHÔNG dùng `Bundle.module` (accessor đó crash khi
/// không tìm thấy bundle, ví dụ trong .app). Tìm ở: Contents/Resources của .app, thư mục chứa
/// executable (`swift run`). Không thấy thì trả nil để UI dùng SF Symbol.
enum AppLogo {
    static let image: NSImage? = {
        let bundleName = "SSHDesk_SSHDesk.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let b = Bundle(url: root.appendingPathComponent(bundleName)),
                let url = b.url(forResource: "AppLogo", withExtension: "png"),
                let img = NSImage(contentsOf: url)
            {
                return img
            }
        }
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }()
}

struct LogoView: View {
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let img = AppLogo.image {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Image(systemName: "terminal").resizable().scaledToFit().padding(size * 0.2)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
