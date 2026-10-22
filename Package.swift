// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHDesk",
    platforms: [.macOS(.v14)],
    targets: [
        // Logic thuần (model, lưu trữ, sinh lệnh Warp) — không import SwiftUI, test được.
        .target(name: "SSHDeskCore", dependencies: ["AskpassKit"]),
        // Logic phân loại prompt askpass (pure, không Foundation) — dùng chung cho helper và Core.
        .target(name: "AskpassKit"),
        // Lớp UI SwiftUI, chỉ gọi vào SSHDeskCore.
        .executableTarget(
            name: "SSHDesk", dependencies: ["SSHDeskCore"],
            // Logo nhỏ ở thanh tiêu đề. Nạp thủ công (không qua Bundle.module) để không crash trong .app.
            resources: [.process("Resources")]),
        // Helper exec: biến slave pty thành controlling tty rồi exec chương trình đích (chỉ Darwin).
        .executableTarget(name: "sshdesk-ctty"),
        // Helper SSH_ASKPASS: chỉ phụ thuộc Darwin + Security (không AppKit/SwiftUI).
        .executableTarget(name: "sshdesk-askpass", dependencies: ["AskpassKit"]),
        // CLI `sshdesk` (ADR-025): chỉ đọc DB, ghi file yêu cầu. Đặt tên khác `SSHDesk` vì APFS không phân biệt hoa thường.
        .executableTarget(name: "sshdesk-cli", dependencies: ["SSHDeskCore"]),
        .testTarget(
            name: "SSHDeskCoreTests",
            dependencies: ["SSHDeskCore", "AskpassKit", "sshdesk-ctty", "sshdesk-askpass"]),
    ]
)
