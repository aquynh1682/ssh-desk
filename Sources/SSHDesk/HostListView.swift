import SSHDeskCore
import SwiftUI

struct EnvironmentBadge: View {
    let environment: HostEnvironment

    private var style: HostEnvironmentStyle {
        switch environment {
        case .prod: return .warm
        case .stg: return .cool
        default: return .neutral
        }
    }

    var body: some View {
        let color = Theme.environmentColor(style)
        Text(HostPresentation.badgeCode(for: environment))
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.55)))
            .accessibilityLabel("Môi trường \(HostPresentation.title(for: environment))")
    }
}

/// Ô icon server (xanh lá khi đang chọn).
struct ServerGlyph: View {
    var highlighted = false
    var windows = false
    var body: some View {
        Image(systemName: windows ? "desktopcomputer" : "server.rack")
            .font(.system(size: 17))
            .foregroundStyle(highlighted ? Theme.green : Theme.textSecondary)
            .frame(width: 24)
    }
}

/// Quyết định click vào hàng làm gì (thuần, dễ kiểm tra): 1 lần = chọn, 2 lần = mở Warp.
enum RowTap {
    enum Action { case select, open }
    static func action(tapCount: Int) -> Action { tapCount >= 2 ? .open : .select }
}

/// Cột giữa: tiêu đề, bộ lọc, bảng máy chủ.
struct HostListView: View {
    @Bindable var model: AppModel
    @FocusState private var listFocused: Bool

    private static let addressWidth: CGFloat = 140
    private static let envWidth: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Group {
                if model.hosts.isEmpty {
                    emptyState
                } else {
                    table
                }
            }
            .cardStyle()
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.columnTitle).font(.system(size: 26, weight: .bold))
                Text("Máy chủ của bạn, một nơi")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            environmentMenu
            Button {
                model.form = .new
            } label: {
                Label("Thêm máy chủ", systemImage: "plus")
            }
            .buttonStyle(ProminentButtonStyle())
            .help("Thêm máy chủ (⌘N)")
        }
    }

    private var environmentMenu: some View {
        let current = model.effectiveEnvironment
        return Menu {
            Button("Tất cả môi trường") { model.setEnvironmentFilter(nil) }
            Divider()
            ForEach(HostPresentation.environmentOrder, id: \.self) { env in
                Button(HostPresentation.title(for: env)) { model.setEnvironmentFilter(env) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(current.map(HostPresentation.title(for:)) ?? "Tất cả môi trường")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.cardStroke))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Lọc theo môi trường")
    }

    // MARK: Bảng

    private var table: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider().overlay(Theme.divider)
            let hosts = model.visibleHosts
            if model.isGroupedTable && (!hosts.isEmpty || !model.folders.isEmpty) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.tableGroups, id: \.name) { group in
                            groupHeader(group)
                            if !model.collapsedGroups.contains(group.name) {
                                ForEach(group.hosts) { host in row(host) }
                            }
                        }
                    }
                }
            } else if hosts.isEmpty {
                noResults.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(hosts) { host in row(host) }
                    }
                }
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        // Return = Mở Warp; ↑/↓ đổi chọn. Chỉ nhận phím khi bảng đang giữ focus (ô tìm kiếm tự nhận phím của nó).
        .onKeyPress(.return) {
            guard let host = model.selectedHost else { return .ignored }
            Task { await model.open(host) }
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("d")]) { press in
            guard press.modifiers == .command, let host = model.selectedHost else { return .ignored }
            model.beginDuplicate(host)
            return .handled
        }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.downArrow) { moveSelection(1) }
    }

    private func groupHeader(_ group: HostGroup) -> some View {
        let collapsed = model.collapsedGroups.contains(group.name)
        return Button {
            model.toggleGroup(group.name)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold)).frame(width: 14)
                Image(systemName: group.isUncategorized ? "tray" : "folder")
                    .foregroundStyle(Theme.textSecondary)
                Text(group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(group.hosts.count)").font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary).monospacedDigit()
                Spacer()
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.rowHover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Mở nhóm" : "Thu gọn nhóm")
        .accessibilityLabel("\(group.title), \(group.hosts.count) máy chủ, \(collapsed ? "đang thu gọn" : "đang mở")")
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let hosts = model.navigableHosts
        guard !hosts.isEmpty else { return .ignored }
        let current = hosts.firstIndex { $0.id == model.selection }
        let next = current.map { min(hosts.count - 1, max(0, $0 + delta)) } ?? 0
        model.selection = hosts[next].id
        return .handled
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Button {
                model.sortAscending.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("TÊN")
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .disabled(model.sidebar == .recent)
            .help(model.sidebar == .recent ? "Gần đây sắp theo thời gian mở" : "Đổi thứ tự sắp xếp")
            .padding(.leading, 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("ĐỊA CHỈ").frame(width: Self.addressWidth, alignment: .leading)
            Text("MÔI TRƯỜNG").frame(width: Self.envWidth + 14, alignment: .leading)
            Spacer().frame(width: 28 + 28 + 8)
        }
        .font(.system(size: 11, weight: .semibold)).tracking(0.5)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func row(_ host: HostProfile) -> some View {
        let selected = model.selection == host.id
        return HStack(spacing: 0) {
            HStack(spacing: 10) {
                ServerGlyph(highlighted: selected, windows: host.kind == .windowsRDP)
                Text(host.displayName).font(.system(size: 14.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(HostPresentation.addressText(host))
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: Self.addressWidth, alignment: .leading)
            EnvironmentBadge(environment: host.environment)
                .frame(width: Self.envWidth + 14, alignment: .leading)
            Button {
                Task { await model.toggleFavorite(host) }
            } label: {
                Image(systemName: host.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(host.isFavorite ? Theme.star : Theme.textSecondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(host.isFavorite ? "Bỏ yêu thích" : "Đánh dấu yêu thích")
            .accessibilityLabel(host.isFavorite ? "Bỏ yêu thích" : "Đánh dấu yêu thích")
            Menu {
                hostActions(host)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Thao tác khác")
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(selected ? Theme.rowSelected : .clear)
        .contentShape(Rectangle())
        // Chọn ngay khi nhấn (không chờ phân biệt double-click); double-click = Mở Warp.
        // Hai cử chỉ chạy đồng thời để single-click không bị trễ/nuốt. Nút sao và ⋯ tự xử lý click của chúng.
        .simultaneousGesture(
            TapGesture().onEnded {
                if RowTap.action(tapCount: 1) == .select {
                    model.selection = host.id
                    listFocused = true
                }
            }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if RowTap.action(tapCount: 2) == .open {
                    model.selection = host.id
                    Task { await model.open(host) }
                }
            }
        )
        .contextMenu { hostActions(host) }
        .onDrag {
            model.selection = host.id
            return NSItemProvider(object: HostFolders.dragPayload([host.id]) as NSString)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func hostActions(_ host: HostProfile) -> some View {
        if host.kind == .windowsRDP {
            Button("Mở Windows App") { Task { await model.openInWindowsApp(host) } }
            Button("Hiện file .rdp trong Finder") { Task { await model.revealRDPFile(host) } }
        } else {
            Button("Mở Warp") { Task { await model.openInWarp(host) } }
            Button("Copy lệnh SSH") { Task { await model.copySSHCommand(host) } }
        }
        Divider()
        if !model.folders.isEmpty {
            Menu("Chuyển vào thư mục") {
                ForEach(model.folders, id: \.self) { f in
                    Button(f) { Task { await model.moveHosts([host.id], toFolder: f) } }
                        .disabled(host.project == f)
                }
                if !host.project.isEmpty {
                    Divider()
                    Button("Chưa phân loại") { Task { await model.moveHosts([host.id], toFolder: nil) } }
                }
            }
        }
        Button("Sửa…") { model.form = .edit(host) }
        Button {
            model.beginDuplicate(host)
        } label: {
            Label("Nhân bản…", systemImage: "plus.square.on.square")
        }
        Button("Xoá…", role: .destructive) { model.pendingDelete = host }
    }

    // MARK: Trống

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Chưa có máy chủ nào", systemImage: "server.rack")
        } description: {
            Text("Thêm máy chủ thủ công hoặc import các alias có sẵn trong ~/.ssh/config.")
        } actions: {
            Button("Thêm máy chủ") { model.form = .new }.buttonStyle(.borderedProminent)
            Button("Import từ SSH config") { model.showImport = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noResults: some View {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search
        } else {
            ContentUnavailableView(
                "Không có máy chủ nào ở đây", systemImage: "tray",
                description: Text("Đổi mục ở thanh bên hoặc bộ lọc môi trường."))
        }
    }
}
