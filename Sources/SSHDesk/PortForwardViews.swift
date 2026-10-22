import SSHDeskCore
import SwiftUI

/// Mục tiêu của form thêm/sửa port forward.
enum ForwardFormTarget: Identifiable {
    case new(hostID: UUID)
    case edit(PortForward)

    var id: String {
        switch self {
        case .new(let hostID): return "new-" + hostID.uuidString
        case .edit(let f): return f.id.uuidString
        }
    }
}

/// Mục "Port forward" trong chi tiết máy chủ (ẩn với máy Windows). ADR-011.
struct PortForwardSection: View {
    @Bindable var model: AppModel
    let host: HostProfile
    @Local private var pendingDelete: PortForward?

    var body: some View {
        let list = model.forwards(for: host.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Port forward").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    model.forwardForm = .new(hostID: host.id)
                } label: {
                    Image(systemName: "plus").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain).help("Thêm port forward")
                .accessibilityLabel("Thêm port forward")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            if list.isEmpty {
                Divider().overlay(Theme.divider)
                Text("Chưa có forward. Thêm để mở cổng trên máy này (127.0.0.1) dẫn tới dịch vụ phía server qua SSH.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .padding(14)
            }
            ForEach(list) { f in
                Divider().overlay(Theme.divider)
                ForwardRow(model: model, forward: f) { pendingDelete = f }
            }
        }
        .cardStyle()
        .confirmationDialog(
            "Xoá forward “\(pendingDelete?.summary ?? "")”?",
            isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Xoá", role: .destructive) {
                if let f = pendingDelete { Task { await model.deleteForward(f) } }
                pendingDelete = nil
            }
            Button("Huỷ", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Chỉ xoá cấu hình trong SSH Desk; tunnel đang chạy (nếu có) sẽ được dừng.")
        }
    }
}

private struct ForwardRow: View {
    @Bindable var model: AppModel
    let forward: PortForward
    let onDelete: () -> Void

    var body: some View {
        let status = model.tunnels.status(of: forward.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color(status)).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if !forward.name.isEmpty {
                        Text(forward.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    }
                    Text(forward.summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer(minLength: 4)
                if status.isActive {
                    Button("Dừng") { model.tunnels.stop(forward) }
                        .controlSize(.small)
                } else {
                    Button(isFailed(status) ? "Chạy lại" : "Mở") { model.tunnels.start(forward) }
                        .controlSize(.small)
                }
                Menu {
                    Button("Copy \(forward.localAddress)") {
                        model.copyValue(forward.localAddress, label: "địa chỉ forward")
                    }
                    Divider()
                    Button("Sửa…") { model.forwardForm = .edit(forward) }
                        .disabled(status.isActive)
                    Button("Xoá…", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Thao tác forward")
            }
            Text(statusText(status))
                .font(.system(size: 12))
                .foregroundStyle(isFailed(status) ? Theme.red : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func isFailed(_ s: TunnelStatus) -> Bool {
        if case .failed = s { return true } else { return false }
    }

    private func color(_ s: TunnelStatus) -> Color {
        switch s {
        case .running: return Theme.green
        case .connecting: return Theme.amber
        case .failed: return Theme.red
        case .stopped: return Theme.textTertiary
        }
    }

    private func statusText(_ s: TunnelStatus) -> String {
        switch s {
        case .stopped: return "Dừng"
        case .connecting: return "Đang kết nối…"
        case .running: return "Đang chạy — kết nối tới \(forward.localAddress)"
        case .failed(let reason): return "Lỗi: \(reason)"
        }
    }
}

/// Form thêm/sửa một forward.
struct PortForwardFormView: View {
    @Bindable var model: AppModel
    let target: ForwardFormTarget
    @Environment(\.dismiss) private var dismiss

    @Local private var name = ""
    @Local private var localText = ""
    @Local private var remoteHost = ""
    @Local private var remoteText = ""
    @Local private var loaded = false
    @Local private var saving = false

    private var existing: PortForward? {
        if case .edit(let f) = target { return f } else { return nil }
    }

    private var hostID: UUID {
        switch target {
        case .new(let id): return id
        case .edit(let f): return f.hostID
        }
    }

    private var candidate: PortForward? {
        guard let lp = Int(localText.trimmingCharacters(in: .whitespaces)),
            let rp = Int(remoteText.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return PortForward(
            id: existing?.id ?? UUID(), hostID: hostID, name: name, localPort: lp,
            remoteHost: remoteHost, remotePort: rp)
    }

    private var error: String? {
        guard !localText.isEmpty || !remoteText.isEmpty else { return nil }
        guard let candidate else { return "Cổng phải là số." }
        do {
            let v = try candidate.validated()
            if let other = model.forwards.first(where: { $0.localPort == v.localPort && $0.id != v.id }) {
                return
                    "Cổng local \(v.localPort) đã được forward “\(other.name.isEmpty ? other.summary : other.name)” dùng."
            }
            return nil
        } catch {
            return AppModel.message(for: error)
        }
    }

    private var canSave: Bool {
        guard let candidate, error == nil, !saving else { return false }
        return (try? candidate.validated()) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Thêm port forward" : "Sửa port forward").font(.title3.bold())
            Form {
                TextField("Tên (tuỳ chọn)", text: $name, prompt: Text("Postgres"))
                TextField("Cổng local", text: $localText, prompt: Text("15432 (1024–65535)"))
                TextField("Máy đích", text: $remoteHost, prompt: Text("localhost"))
                TextField("Cổng đích", text: $remoteText, prompt: Text("5432"))
            }
            Text(
                "Mở 127.0.0.1:<cổng local> trên máy này → <máy đích>:<cổng đích> tính từ phía server. Chỉ nghe trên 127.0.0.1, không mở ra mạng LAN."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let f = existing {
                name = f.name
                localText = String(f.localPort)
                remoteHost = f.remoteHost
                remoteText = String(f.remotePort)
            }
        }
    }

    private func save() async {
        guard let candidate else { return }
        saving = true
        let ok = await model.saveForward(candidate, isNew: existing == nil)
        saving = false
        if ok { dismiss() }
    }
}
