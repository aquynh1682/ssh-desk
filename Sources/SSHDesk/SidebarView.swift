import SSHDeskCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    header("WORKSPACE", first: true)
                    row("Tất cả máy chủ", "server.rack", item: .all)
                    row("Yêu thích", "star", item: .favorites)
                    row(
                        "Truyền file", "arrow.up.arrow.down", item: .transfers,
                        badge: TransferPresentation.active(model.jobs).count)
                    row("Gần đây", "clock", item: .recent)
                    analystRow
                    monitorRow

                    if model.sidebar == .analyst || model.sidebar == .monitor {
                        // PROJECTS thay MÔI TRƯỜNG + THƯ MỤC khi ở Project Analyst: project chính là thư mục.
                        ProjectsSection(model: model)
                    } else {
                        let counts = HostPresentation.environmentCounts(model.hosts)
                        if !counts.isEmpty {
                            header("MÔI TRƯỜNG")
                            ForEach(counts, id: \.environment) { c in
                                row(
                                    HostPresentation.title(for: c.environment), "server.rack",
                                    item: .environment(c.environment), trailing: "\(c.count)")
                            }
                        }
                        folderSection
                    }
                }
                .padding(.horizontal, 10).padding(.top, 12)
            }
            Divider().overlay(Theme.divider).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 2) {
                row("SSH Keys", "key", item: .keys)
                row("Cài đặt", "gearshape", item: .settings)
            }
            .padding(10)
        }
        .frame(width: Theme.sidebarWidth)
        .background(Theme.sidebarBackground)
        .sheet(item: nameSheetBinding) { dialog in
            if case .rename(let name) = dialog {
                FolderNameSheet(model: model, renaming: name)
            } else {
                FolderNameSheet(model: model, renaming: nil)
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { if case .confirmDelete = model.folderDialog { return true } else { return false } },
                set: { if !$0, case .confirmDelete = model.folderDialog { model.folderDialog = nil } }),
            titleVisibility: .visible
        ) {
            if case .confirmDelete(let name) = model.folderDialog {
                Button("Xoá thư mục", role: .destructive) {
                    model.folderDialog = nil
                    Task { await model.deleteFolder(name) }
                }
            }
            Button("Huỷ", role: .cancel) { model.folderDialog = nil }
        } message: {
            Text("Chỉ xoá nhóm: các máy chủ trong đó chuyển về “Chưa phân loại”, không bị xoá.")
        }
        .confirmationDialog(
            "Thư mục đã tồn tại",
            isPresented: Binding(
                get: { if case .confirmMerge = model.folderDialog { return true } else { return false } },
                set: { if !$0, case .confirmMerge = model.folderDialog { model.folderDialog = nil } }),
            titleVisibility: .visible
        ) {
            if case .confirmMerge(let from, let to) = model.folderDialog {
                Button("Gộp vào “\(to)”") {
                    model.folderDialog = nil
                    Task { _ = await model.renameFolder(from, to: to, merge: true) }
                }
            }
            Button("Huỷ", role: .cancel) { model.folderDialog = nil }
        } message: {
            if case .confirmMerge(let from, let to) = model.folderDialog {
                Text("Đã có thư mục “\(to)”. Gộp mọi máy chủ của “\(from)” vào đó?")
            }
        }
    }

    /// Chỉ create/rename mở sheet; các hộp thoại xác nhận dùng confirmationDialog.
    private var nameSheetBinding: Binding<FolderDialog?> {
        Binding(
            get: {
                switch model.folderDialog {
                case .create, .rename: return model.folderDialog
                default: return nil
                }
            },
            set: { newValue in
                if newValue == nil {
                    switch model.folderDialog {
                    case .create, .rename: model.folderDialog = nil
                    default: break
                    }
                }
            })
    }

    private var deleteTitle: String {
        if case .confirmDelete(let name) = model.folderDialog { return "Xoá thư mục “\(name)”?" }
        return ""
    }

    // MARK: Thư mục

    @ViewBuilder
    private var folderSection: some View {
        let counts = model.folderCounts
        HStack {
            header("THƯ MỤC")
            Spacer()
            Button {
                model.inventory.openHub()
            } label: {
                Image(systemName: "tablecells.badge.ellipsis").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 16)
            .help("Nguồn máy chủ…").accessibilityLabel("Nguồn máy chủ")
            Button {
                model.folderDialog = .create
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 16)
            .help("Tạo thư mục mới").accessibilityLabel("Tạo thư mục mới")
        }
        ForEach(counts, id: \.name) { c in
            FolderRow(
                model: model, title: c.name, symbol: "folder", count: c.count,
                item: .folder(c.name), dropFolder: c.name
            ) {
                Button("Đổi tên…") { model.folderDialog = .rename(c.name) }
                Button("Gán bộ đăng nhập…") { model.assignSetTarget = AssignSetTarget(folder: c.name) }
                    .disabled(model.credentialSets.isEmpty)
                Button("Xoá thư mục…", role: .destructive) {
                    model.folderDialog = .confirmDelete(c.name)
                }
            }
        }
        if model.uncategorizedCount > 0 || !counts.isEmpty {
            FolderRow(
                model: model, title: HostFolders.uncategorizedTitle, symbol: "tray",
                count: model.uncategorizedCount, item: .uncategorized, dropFolder: nil
            ) {}
        }
        if counts.isEmpty && model.uncategorizedCount == 0 {
            Text("Chưa có thư mục").font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary).padding(.horizontal, 10)
        }
    }

    private var analystRow: some View {
        let selected = model.sidebar == .analyst
        return Button {
            model.sidebar = .analyst
            model.analyst.enter()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").frame(width: 20)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Text("Project Analyst").lineLimit(1)
                Spacer(minLength: 4)
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var monitorRow: some View {
        let selected = model.sidebar == .monitor
        return Button {
            model.sidebar = .monitor
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent").frame(width: 20)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Text("Monitor").lineLimit(1)
                Spacer(minLength: 4)
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func header(_ text: String, first: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10).padding(.top, first ? 4 : 16).padding(.bottom, 4)
    }

    private func row(
        _ title: String, _ symbol: String, item: SidebarItem, trailing: String? = nil,
        badge: Int = 0
    ) -> some View {
        let selected = model.sidebar == item
        return Button {
            model.sidebar = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.rowSelected, in: Capsule())
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Hàng thư mục ở thanh bên: chọn để lọc, nhận host kéo thả vào.
private struct FolderRow<Menu: View>: View {
    @Bindable var model: AppModel
    let title: String
    let symbol: String
    let count: Int
    let item: SidebarItem
    /// Tên thư mục đích khi thả; `nil` = Chưa phân loại.
    let dropFolder: String?
    @ViewBuilder let menu: () -> Menu
    @Local private var targeted = false

    var body: some View {
        let selected = model.sidebar == item
        Button {
            model.sidebar = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: targeted ? "folder.fill.badge.plus" : symbol).frame(width: 20)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").foregroundStyle(Theme.textSecondary).monospacedDigit()
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                targeted ? Theme.green.opacity(0.18) : (selected ? Theme.rowSelected : .clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.green, lineWidth: targeted ? 1.5 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu() }
        .onDrop(of: [.plainText], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            let target = dropFolder
            let model = model
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                let text = (object as? NSString).map { $0 as String }
                guard let text, let ids = HostFolders.parseDragPayload(text) else { return }
                Task { @MainActor in await model.moveHosts(ids, toFolder: target) }
            }
            return true
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Sheet nhập tên thư mục (tạo mới hoặc đổi tên).
struct FolderNameSheet: View {
    @Bindable var model: AppModel
    /// `nil` = tạo mới.
    let renaming: String?
    @Environment(\.dismiss) private var dismiss
    @Local private var name = ""
    @Local private var loaded = false

    private var error: String? {
        if name.isEmpty { return nil }
        do { _ = try HostFolders.normalize(name) } catch { return AppModel.message(for: error) }
        return nil
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && error == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(renaming == nil ? "Thư mục mới" : "Đổi tên thư mục")
                .font(.system(size: 15, weight: .semibold))
            TextField("Tên thư mục", text: $name).onSubmit(submit)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(renaming == nil ? "Tạo" : "Đổi tên", action: submit)
                    .keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }
        .padding(18).frame(width: 340)
        .onAppear {
            if !loaded {
                loaded = true
                name = renaming ?? ""
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            let ok: Bool
            if let renaming {
                ok = await model.renameFolder(renaming, to: name)
            } else {
                ok = await model.createFolder(name)
            }
            // Đổi tên trùng → model đã chuyển sang hộp thoại hỏi gộp; sheet này đóng như thường.
            if ok { dismiss() }
        }
    }
}

/// Mục PROJECTS (chỉ hiện ở Project Analyst và Monitor): thư mục dạng cây; mở ra thấy máy chủ, chấm phiên, badge môi trường.
private struct ProjectsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let analyst = model.analyst
        let monitor = model.monitor
        let inMonitor = model.sidebar == .monitor
        Text("PROJECTS")
            .font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
        ForEach(model.folderCounts, id: \.name) { c in
            let open = inMonitor ? monitor.expanded.contains(c.name) : analyst.expanded.contains(c.name)
            let selected = (inMonitor ? monitor.folder : analyst.folder) == c.name
            HStack(spacing: 6) {
                Button {
                    if inMonitor {
                        if open { monitor.expanded.remove(c.name) } else { monitor.expanded.insert(c.name) }
                    } else {
                        if open { analyst.expanded.remove(c.name) } else { analyst.expanded.insert(c.name) }
                    }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.textSecondary).frame(width: 16, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(open ? "Thu gọn \(c.name)" : "Mở rộng \(c.name)")
                Button {
                    if inMonitor { monitor.select(c.name) } else { analyst.select(c.name) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.blue)
                        Text(c.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(c.count)").foregroundStyle(Theme.textSecondary).monospacedDigit()
                    }
                    .font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .background(selected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityAddTraits(selected ? .isSelected : [])
            if open {
                let hosts = HostPresentation.sortedByName(
                    model.hosts.filter { $0.project == c.name }, ascending: true)
                ForEach(hosts) { h in
                    let live = inMonitor ? monitor.states[h.id]?.status == .ok : analyst.isLive(h.id)
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(live ? Theme.green : Theme.textTertiary)
                            .frame(width: 8, height: 8).padding(.top, 5)
                            .accessibilityLabel(live ? "Đã kết nối" : "Chưa kết nối")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.displayName).font(.system(size: 13)).lineLimit(1)
                            Text(HostPresentation.addressText(h))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(HostPresentation.badgeCode(for: h.environment))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(h.environment == .prod ? Theme.amber : Theme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.rowSelected, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .padding(.leading, 28).padding(.trailing, 6).padding(.vertical, 3)
                    .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        if model.folderCounts.isEmpty {
            Text("Chưa có thư mục").font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary).padding(.horizontal, 10)
        }
    }
}
