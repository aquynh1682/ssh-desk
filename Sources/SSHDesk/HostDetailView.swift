import SSHDeskCore
import SwiftUI

/// Cột phải: chi tiết máy chủ đang chọn.
struct HostDetailView: View {
    @Bindable var model: AppModel
    let host: HostProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let banner = model.banner { bannerView(banner) }
                Button {
                    Task { await model.open(host) }
                } label: {
                    Label(
                        isWindows ? "Mở Windows App" : "Mở Warp",
                        systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(ProminentButtonStyle(fullWidth: true))
                .help(
                    isWindows
                        ? "Mở kết nối RDP trong Windows App (Return khi đang ở danh sách)"
                        : "Mở phiên SSH trong Warp (Return khi đang ở danh sách)")
                loginCard
                HostSourceCard(model: model, host: host)
                connectionCard
                if isWindows {
                    Text(
                        model.hasStoredPassword(host)
                            ? "Khi mở, mật khẩu được copy để bạn dán (⌘V) vào Windows App; clipboard tự xoá sau 30 giây."
                            : "Mật khẩu nhập trong Windows App."
                    )
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    HStack(spacing: 10) {
                        Button {
                            model.transferSheet = .upload(host)
                        } label: {
                            Label("Tải lên", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(OutlineButtonStyle(fullWidth: true))
                        .help("Tải file/thư mục từ máy này lên server")
                        Button {
                            model.transferSheet = .download(host)
                        } label: {
                            Label("Tải về", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(OutlineButtonStyle(fullWidth: true))
                        .help("Tải file/thư mục từ server về máy này")
                    }
                }
                if !isWindows { PortForwardSection(model: model, host: host) }
                infoCard
            }
            .padding(18)
        }
        .frame(width: Theme.detailWidth)
    }

    private var isWindows: Bool { host.kind == .windowsRDP }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isWindows ? "desktopcomputer" : "server.rack")
                .font(.system(size: 22)).foregroundStyle(Theme.green)
                .frame(width: 52, height: 52)
                .background(Theme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.green.opacity(0.4)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(host.displayName).font(.system(size: 18, weight: .bold)).lineLimit(2)
                    EnvironmentBadge(environment: host.environment)
                }
                let sub = HostPresentation.subtitle(host)
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if isWindows {
                    Button("Mở Windows App") { Task { await model.openInWindowsApp(host) } }
                    if model.hasStoredPassword(host) {
                        Button("Copy mật khẩu") { Task { await model.copyWindowsPassword(host) } }
                    }
                    Button("Hiện file .rdp trong Finder") {
                        Task { await model.revealRDPFile(host) }
                    }
                    Divider()
                }
                Button("Sửa…") { model.form = .edit(host) }
                Button {
                    model.beginDuplicate(host)
                } label: {
                    Label("Nhân bản…", systemImage: "plus.square.on.square")
                }
                if !isWindows {
                    Button("Copy lệnh SSH") { Task { await model.copySSHCommand(host) } }
                    Button("Cài key…") { model.keys.pickKeyForHost = host }
                }
                Divider()
                Button("Xoá…", role: .destructive) { model.pendingDelete = host }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Thao tác khác")
        }
    }

    /// Nguồn mật khẩu, cảnh báo key mất và banner hold (ADR-026/030).
    @ViewBuilder
    private var loginCard: some View {
        let source = model.passwordSource(for: host)
        let missingKey = model.missingKeyPath(for: host)
        let ownOverrides: Bool = { if case .ownOverridesSet = source { return true } else { return false } }()
        if host.autofillHold || source != .none || missingKey != nil || host.credentialSetID != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Đăng nhập").font(.system(size: 14, weight: .semibold))
                if source != .none {
                    HStack {
                        Label(source.label, systemImage: "key.fill").font(.system(size: 13))
                        Spacer(minLength: 0)
                        if ownOverrides || source == .own {
                            Button("Xoá mật khẩu riêng") {
                                Task { _ = await model.clearPassword(hostID: host.id) }
                            }
                            .controlSize(.small)
                        }
                    }
                } else if let set = model.credentialSet(id: host.credentialSetID) {
                    Text("Bộ đăng nhập: \(set.name) (chưa có mật khẩu)")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                if model.needsReauth(host) {
                    Label(
                        "Mật khẩu đã lưu không còn dùng được trên máy này — nhập lại",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 12.5)).foregroundStyle(Theme.amber)
                }
                if let missingKey {
                    Label("Không thấy file key \(missingKey)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.amber)
                }
                if host.autofillHold {
                    HStack(alignment: .top) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber)
                        Text(
                            "\(host.autofillHoldReason ?? "Cần xác nhận"). Đã tạm tắt tự điền mật khẩu cho máy này."
                        )
                        .font(.system(size: 12.5))
                        Spacer(minLength: 0)
                        Button("Xác nhận") { Task { await model.confirmAutofillHold(host) } }
                            .controlSize(.small)
                    }
                    .padding(10)
                    .background(Theme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private var connectionCard: some View {
        let rows = HostPresentation.connectionRows(
            host, jumpHostName: model.name(of: host.jumpHostID),
            credentialSet: model.credentialSet(id: host.credentialSetID),
            hasSavedPassword: isWindows && model.hasStoredPassword(host))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Kết nối").font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 12)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Divider().overlay(Theme.divider)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(r.label).foregroundStyle(Theme.textSecondary)
                        .frame(width: 92, alignment: .leading)
                    Text(r.value)
                        .font(
                            r.label == "Xác thực"
                                ? .system(size: 13) : .system(size: 13, design: .monospaced)
                        )
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if r.copyable {
                        Button {
                            model.copyValue(r.value, label: r.label.lowercased())
                        } label: {
                            Image(systemName: "doc.on.doc").foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain).help("Copy \(r.label)")
                        .accessibilityLabel("Copy \(r.label)")
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var infoCard: some View {
        let hasInfo =
            !host.project.isEmpty || !host.tags.isEmpty || !host.notes.isEmpty
            || !host.remoteBookmarks.isEmpty || host.lastLaunchRequestedAt != nil
        if hasInfo {
            VStack(alignment: .leading, spacing: 8) {
                Text("Thông tin").font(.system(size: 14, weight: .semibold))
                if !host.project.isEmpty { info("Thư mục", host.project) }
                if !host.tags.isEmpty { info("Tags", host.tags.joined(separator: ", ")) }
                if !host.notes.isEmpty { info("Ghi chú", host.notes) }
                ForEach(Array(host.remoteBookmarks.enumerated()), id: \.offset) { _, b in
                    info("Bookmark", "\(b.name): \(b.path)")
                }
                if let last = host.lastLaunchRequestedAt {
                    info(
                        isWindows ? "Mở Windows App lần cuối" : "Mở Warp lần cuối",
                        last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Theme.textSecondary).frame(width: 92, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
    }

    private func bannerView(_ banner: Banner) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
            Text(banner.text).font(.system(size: 12.5))
            Spacer(minLength: 0)
            if banner.showsAppStoreLink {
                Button("Mở App Store") { model.openWindowsAppStore() }.controlSize(.small)
            } else if !isWindows {
                Button("Copy lệnh SSH") { Task { await model.copySSHCommand(host) } }
                    .controlSize(.small)
            }
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Theme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
    }
}
