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
                    Task { await model.openInWarp(host) }
                } label: {
                    Label("Mở Warp", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(ProminentButtonStyle(fullWidth: true))
                .help("Mở phiên SSH trong Warp (Return khi đang ở danh sách)")
                connectionCard
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
                infoCard
            }
            .padding(18)
        }
        .frame(width: Theme.detailWidth)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack")
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
                Button("Sửa…") { model.form = .edit(host) }
                Button {
                    model.beginDuplicate(host)
                } label: {
                    Label("Nhân bản…", systemImage: "plus.square.on.square")
                }
                Button("Copy lệnh SSH") { Task { await model.copySSHCommand(host) } }
                Button("Cài key…") { model.keys.pickKeyForHost = host }
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

    private var connectionCard: some View {
        let rows = HostPresentation.connectionRows(
            host, jumpHostName: model.name(of: host.jumpHostID))
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
                    info("Mở Warp lần cuối", last.formatted(date: .abbreviated, time: .shortened))
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
            Button("Copy lệnh SSH") { Task { await model.copySSHCommand(host) } }
                .controlSize(.small)
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
