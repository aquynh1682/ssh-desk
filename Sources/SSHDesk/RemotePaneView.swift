import SSHDeskCore
import SwiftUI

/// Khung phải: dải tab theo host + duyệt file remote.
struct RemotePaneView: View {
    @Bindable var browser: FileBrowserModel
    let hosts: [HostProfile]
    @Local private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            if let tab = browser.selectedTab {
                RemoteTabView(browser: browser, tab: tab)
                    .id(tab.id)
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Chưa mở máy chủ nào", systemImage: "server.rack")
        } description: {
            Text("Bấm + để chọn máy chủ, rồi kéo file từ khung bên trái sang đây.")
        } actions: {
            Button("Chọn máy chủ…") { showPicker = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardStyle()
    }

    // MARK: - Dải tab

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(browser.tabs) { tab in TabChip(browser: browser, tab: tab) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            Button {
                showPicker = true
            } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 32).contentShape(Rectangle())
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
            }
            .buttonStyle(.plain).help("Mở máy chủ trong tab mới").accessibilityLabel("Mở tab máy chủ")
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                HostPickerPopover(browser: browser, hosts: hosts) { showPicker = false }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 6)
    }
}

private struct TabChip: View {
    @Bindable var browser: FileBrowserModel
    let tab: BrowserTab

    var body: some View {
        let selected = browser.selectedTabID == tab.id
        HStack(spacing: 8) {
            StatusDot(state: tab.state)
            Text(tab.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
            Button {
                browser.requestClose(tab)
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Đóng tab (ngắt kết nối)").accessibilityLabel("Đóng tab \(tab.title)")
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12).frame(height: 32)
        .background(selected ? Theme.card : Theme.control.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(
                selected ? Theme.textTertiary.opacity(0.6) : Theme.cardStroke)
        )
        .contentShape(Rectangle())
        .onTapGesture { browser.selectedTabID = tab.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StatusDot: View {
    let state: BrowserTabState

    var body: some View {
        let color: Color
        switch BrowserTabPresentation.dot(state) {
        case .green: color = Theme.green
        case .yellow: color = Theme.amber
        case .red: color = Theme.red
        }
        return Circle().fill(color).frame(width: 9, height: 9)
            .accessibilityLabel(BrowserTabPresentation.statusText(state))
    }
}

/// Nội dung của một tab: dòng thông tin, thanh điều hướng, bảng, chân.
private struct RemoteTabView: View {
    @Bindable var browser: FileBrowserModel
    @Bindable var tab: BrowserTab
    @Local private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            infoRow
            PaneNavBar(
                canBack: tab.history?.canGoBack ?? false, canForward: tab.history?.canGoForward ?? false,
                canUp: tab.isBrowsable && BrowserPath.parent(tab.path) != tab.path,
                onBack: { Task { await tab.load(.back) } },
                onForward: { Task { await tab.load(.forward) } },
                onUp: { Task { await tab.goUp() } },
                pathText: $tab.pathText,
                onSubmit: { Task { await tab.submitPathText() } },
                showSearch: $tab.showSearch,
                onRefresh: { Task { await tab.refresh() } },
                onNewFolder: { browser.promptNewRemoteFolder(tab) },
                actionsEnabled: tab.isBrowsable
            ) {
                menuItems
            }
            PaneSearchBar(query: $tab.query, visible: $tab.showSearch)
            Divider().overlay(Theme.divider)
            if let error = tab.listError {
                PaneErrorBar(message: error) { tab.listError = nil }
            }
            content
            Divider().overlay(Theme.divider)
            PaneFooter(
                text: tab.isBrowsable
                    ? BrowserFormat.footerText(
                        total: tab.rows.count, selected: tab.selection.selected.count)
                    : BrowserTabPresentation.statusText(tab.state),
                warning: tab.unparsedLines > 0
                    ? "\(tab.unparsedLines) dòng không đọc được" : nil)
        }
        .cardStyle()
        .onDrop(of: [.browserItems, .fileURL], isTargeted: $targeted) { providers in
            browser.handleDrop(providers, onRemote: tab)
            return true
        }
    }

    // MARK: Dòng thông tin

    private var infoRow: some View {
        HStack(spacing: 10) {
            StatusDot(state: tab.state)
            Text(BrowserTabPresentation.identity(tab.host))
                .font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            EnvironmentTag(environment: tab.host.environment)
            Divider().frame(height: 14)
            Text(BrowserTabPresentation.statusText(tab.state))
                .font(.system(size: 13))
                .foregroundStyle(BrowserTabPresentation.canReconnect(tab.state) ? Theme.red : Theme.textSecondary)
            if BrowserTabPresentation.canReconnect(tab.state) {
                Text("—").foregroundStyle(Theme.textSecondary)
                Button("Kết nối lại") { Task { await tab.start() } }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.blue)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .help(BrowserTabPresentation.detail(tab.state) ?? "")
    }

    // MARK: Bảng và trạng thái

    @ViewBuilder
    private var content: some View {
        switch tab.state {
        case .connected:
            FileTable(
                style: .remote, rows: tab.rows, selection: tab.selection.selected, sort: tab.sort,
                onSort: { tab.sort = tab.sort.toggled($0) },
                onClick: { row, modifier in
                    tab.selection.click(row.id, modifier: modifier, order: tab.rows.map(\.id))
                },
                onOpen: { row in Task { await tab.open(row) } },
                onClearSelection: { tab.selection.clear() },
                makeProvider: { rows in
                    browser.provider(
                        for: rows.map(BatchItem.init(row:)), origin: .remote(hostID: tab.hostID))
                },
                menu: { row in rowMenu(row) }
            )
            .overlay(alignment: .bottom) {
                if browser.shouldShowDropOverlay(onRemote: tab, targeted: targeted) {
                    DropZoneOverlay(
                        symbol: "arrow.up.to.line", title: "Tải lên \(tab.title)", detail: tab.path)
                }
            }
        case .connecting, .awaitingAuth:
            VStack(spacing: 10) {
                ProgressView()
                Text(BrowserTabPresentation.statusText(tab.state)).foregroundStyle(Theme.textSecondary)
                if tab.state == .awaitingAuth {
                    Text("Nhập thông tin ở thẻ xác thực góc dưới bên phải.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disconnected(let reason):
            VStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 30))
                    .foregroundStyle(Theme.red)
                Text("Mất kết nối").font(.system(size: 15, weight: .semibold))
                if !reason.isEmpty {
                    Text(reason).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                }
                Button("Kết nối lại") { Task { await tab.start() } }.buttonStyle(ProminentButtonStyle())
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: BrowserRow) -> some View {
        if row.isDirectory || row.isSymlink {
            Button("Mở") { Task { await tab.open(row) } }
        }
        Button("Tải về") {
            Task {
                if !tab.selection.selected.contains(row.id) {
                    tab.selection.click(row.id, modifier: .none, order: tab.rows.map(\.id))
                }
                await browser.downloadSelected(from: tab)
            }
        }
        Divider()
        Button("Đổi tên…") { browser.promptRenameRemote(tab, row) }
        Button("Xoá…", role: .destructive) { browser.confirmDeleteRemote(tab, row) }
        Button("Sao chép đường dẫn") { tab.copyPath(row) }
    }

    @ViewBuilder
    private var menuItems: some View {
        let selected = tab.selectedRows
        Button("Tải về") { Task { await browser.downloadSelected(from: tab) } }
            .disabled(selected.isEmpty)
        Divider()
        Button("Đổi tên…") {
            if let row = selected.first { browser.promptRenameRemote(tab, row) }
        }
        .disabled(selected.count != 1)
        Button("Xoá…", role: .destructive) {
            if let row = selected.first { browser.confirmDeleteRemote(tab, row) }
        }
        .disabled(selected.count != 1)
        Button("Sao chép đường dẫn") {
            if let row = selected.first { tab.copyPath(row) }
        }
        .disabled(selected.count != 1)
    }
}

/// Badge môi trường; PROD nổi bật (nền đặc).
struct EnvironmentTag: View {
    let environment: HostEnvironment

    var body: some View {
        if environment == .prod {
            Text(HostPresentation.badgeCode(for: .prod))
                .font(.system(size: 11, weight: .heavy))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(Color.black)
                .background(Theme.amber, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Môi trường Production")
        } else {
            EnvironmentBadge(environment: environment)
        }
    }
}

/// Popover chọn host (tìm kiếm, nhóm theo môi trường). Host đã có tab → chuyển sang tab đó.
struct HostPickerPopover: View {
    @Bindable var browser: FileBrowserModel
    let hosts: [HostProfile]
    let dismiss: () -> Void
    @Local private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let groups = HostPicker.groups(hosts, query: query)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Tìm máy chủ", text: $query).textFieldStyle(.plain).focused($focused)
            }
            .padding(10)
            Divider()
            if groups.isEmpty {
                Text(hosts.isEmpty ? "Chưa có máy chủ nào." : "Không có máy chủ khớp.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(groups, id: \.environment) { group in
                            Text(HostPresentation.title(for: group.environment).uppercased())
                                .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                            ForEach(group.hosts) { host in row(host) }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 320, height: 340)
        .onAppear { focused = true }
    }

    private func row(_ host: HostProfile) -> some View {
        let open = browser.tabs.first { $0.hostID == host.id }
        let usable = HostPicker.isSelectable(host)
        return Button {
            dismiss()
            Task { await browser.openTab(host) }
        } label: {
            HStack(spacing: 8) {
                if let open { StatusDot(state: open.state) } else { Color.clear.frame(width: 9, height: 9) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.displayName).font(.system(size: 13.5)).lineLimit(1)
                    Text(BrowserTabPresentation.identity(host))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if open != nil { Text("đang mở").font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
                EnvironmentTag(environment: host.environment)
            }
            .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!usable).opacity(usable ? 1 : 0.4)
    }
}
